# frozen_string_literal: true

require_relative "../names"

module Keiyaku
  class Emitter
    # The signature file, which is a second translation of the same document
    # into a language with its own rules: `|` means one thing after `attr_reader`
    # and another after `->`, a name that is not a method cannot be an
    # attr_reader at all, and a component that turned out not to be a class is
    # referred to by a type alias rather than by its constant. None of that has
    # anything to do with what the Ruby emitter is deciding, so it is kept
    # where it can be read as the one subject it is.
    #
    # It is handed the model and union tables rather than a copy of them,
    # because a union component's expansion is worked out while the schemas are
    # still being collected — the tables go on growing behind it.
    class RBS
      SCALARS = {
        ":bool" => "bool", ":any" => "untyped", ":binary" => "String", ":text" => "String",
        ":upload" => "Keiyaku::Upload | IO"
      }.freeze

      def initialize(namespace:, models:, unions:)
        @namespace = namespace
        @models = models
        @unions = unions
      end

      def type_for(source)
        # A recursive type is written as a Proc in the source and as itself here:
        # RBS has no trouble with a class that mentions its own name.
        return type_for(source[/\A-> \{(.*)\}\z/m, 1].strip) if source.start_with?("-> {")
        return "Array[#{type_for(source[1..-2].strip)}]" if source.start_with?("[")
        return "Hash[String, #{type_for(source[/=>(.*)}/m, 1].strip)}]" if source.start_with?("{")

        # A named union is referred to by its alias; an inline one is spelled out.
        if (expansion = @unions[source])
          return source.start_with?("Keiyaku::OneOf[") ? expand_union(expansion) : Keiyaku.snake(source)
        end

        SCALARS[source] || source
      end

      def source(order, operations)
        models = order.map { model_rbs(_1) }
        methods = operations.filter_map { method_rbs(_1) }

        <<~RBS
          #{HEADER}

          module #{@namespace}
          #{models.join("\n\n")}

            class Client < Keiyaku::Client
          #{methods.join("\n")}
            end
          end
        RBS
      end

      private

      # A union is written bare everywhere but one place: RBS reads `|` after a
      # return type as the start of another overload, so `-> A | B` is a syntax
      # error where `attr_reader a: A | B` is fine. Only a top-level `|` needs
      # the parentheses — inside `Array[...]` the brackets already close it off.
      def return_type(type)
        depth = 0
        type.each_char do |char|
          case char
          when "[" then depth += 1
          when "]" then depth -= 1
          when "|" then return "(#{type})" if depth.zero?
          end
        end
        type
      end

      # How the operation's `into:` reads as a return type. `untyped` in a union
      # says nothing the union did not already say and takes the rest of it down
      # with it, so an operation with one response the document left open is
      # that: untyped.
      def into_type(into)
        types = into.values.uniq.map { type_for(_1) }
        types.include?("untyped") ? "untyped" : types.join(" | ")
      end

      # What the enumerator yields: the element of the array being paged over,
      # which is either the response itself or a field of the envelope.
      def paginate_element(op)
        # A page is one shape; an operation whose statuses disagree is not one
        # this can name, and pagination over it would be walking two types.
        return "untyped" unless op[:into]&.size == 1

        source = op[:into].values.first
        if (items = op[:hint]["items"])
          model = @models[source]
          return "untyped" unless model.is_a?(Model)

          source = model.fields[Keiyaku.snake(items)]
        end

        source.to_s.start_with?("[") ? type_for(source[1..-2].strip) : "untyped"
      end

      # RBS has no constant that stands for a union, so a union component becomes
      # a type alias for signatures to use, plus the constant itself for callers
      # that reach for `Event.cast`.
      def union_type(const)
        source = @models[const]
        constant =
          if source.start_with?("Keiyaku::OneOf[") then "Keiyaku::OneOf"
          elsif source == ":any" then "Symbol"
          else "untyped" # a union that collapsed to one type, so the constant is that type
          end

        "  type #{Keiyaku.snake(const)} = #{expand_union(@unions[const])}\n  #{const}: #{constant}"
      end

      # A variant of a union may be a component that turned out not to be a
      # class — an array, a scalar — and RBS refers to one of those by its type
      # alias. The constant is still there, but it holds a value rather than
      # naming a type, so a signature that used it would not resolve.
      def expand_union(expansion)
        expansion.split(" | ").map { |name| @models[name].is_a?(String) ? Keiyaku.snake(name) : name }.join(" | ")
      end

      def model_rbs(const)
        model = @models[const]
        return union_type(const) if model.is_a?(String)

        # `attr_reader "+1":` is not RBS, in either spelling — the name is not
        # a method, so it is typed where it is actually read instead.
        bare, quoted = model.fields.partition { |field, _| Names.bare?(field) }
        declared = lambda do |field, type|
          "#{type_for(type)}#{"?" unless model.required.include?(field)}"
        end

        readers = bare.map { |field, type| "    attr_reader #{field}: #{declared.(field, type)}" }

        # Only the names that cannot be an attr_reader are worth an overload:
        # `[]` is already declared on the base class, and a subclass's `def`
        # replaces that rather than adding to it, so anything left out here is
        # left out of the type entirely. Hence the trailing overload — without
        # it, typing `rollup["+1"]` would cost `rollup[:total]`, which the same
        # method reads perfectly well.
        unless quoted.empty?
          overloads = quoted.map { |field, type| "(#{field.inspect}) -> #{declared.(field, type)}" }
          readers << "    def []: #{(overloads + ["(String | Symbol) -> untyped"]).join("\n           | ")}"
        end

        # `to_json_hash` and `deconstruct_keys` are not emitted: the first is
        # word for word what the base class declares, and the second would be
        # a union of every type in the model, which a pattern match binding one
        # field is not helped by. What is emitted is what is more precise here
        # than it can be there.
        <<~RBS.chomp
            class #{const} < ::Keiyaku::Model
          #{readers.join("\n")}
              def self.cast: (untyped, ?String) -> #{const}
          #{constructors(const, model)}
            end
        RBS
      end

      # `new` and `with`, spelled out. Inherited from Keiyaku::Model they are
      # `(**untyped)`, which typechecks a call site that leaves out a required
      # field and one that misspells an optional one — the two mistakes a
      # signature for a request body exists to catch.
      #
      # An open model still takes anything beyond its fields, so **untyped is
      # the truth there and the declared keywords are what is gained.
      def constructors(const, model)
        keywords = model.fields.filter_map do |field, type|
          next unless Names.bare?(field)

          [field, "#{type_for(type)}#{"?" unless model.required.include?(field)}"]
        end

        required, optional = keywords.partition { |field, _| model.required.include?(field) }
        new_args = required.map { |field, type| "#{field}: #{type}" } +
                   optional.map { |field, type| "?#{field}: #{type}" }
        with_args = keywords.map { |field, type| "?#{field}: #{type}" }

        # A field Ruby will not take as a keyword label cannot be declared as
        # one, so a model with any is as open as one the document opened.
        rest = model.open || keywords.size < model.fields.size ? ["**untyped"] : []

        ["    def self.new: (#{(new_args + rest).join(", ")}) -> #{const}",
         "    def with: (#{(with_args + rest).join(", ")}) -> #{const}"].join("\n")
      end

      def method_rbs(op)
        return if op[:name].nil?
        if op[:unsupported]
          return "    def #{op[:name]}: (*untyped) -> bot  # not generated: #{Emitter.comment(op[:unsupported])}"
        end

        types = op[:types]
        positional = op[:template].scan(/\{(\w+)\}/).flatten.map do |param|
          "#{type_for(types[param] || ":any")} #{Keiyaku.snake(param)}"
        end
        payload = op[:body] || op[:form] || op[:multipart]
        positional << "#{type_for(payload)} body" if payload

        keyword = lambda do |json_name, ruby_name|
          required = op[:required].include?(json_name)
          type = type_for(types[json_name] || ":any")
          "#{"?" unless required}#{Keiyaku.snake(ruby_name)}: #{type}#{"?" unless required}"
        end
        keywords = op[:query].map { keyword.(_1, _1) } +
                   op[:header].map { |json, ruby| keyword.(json, ruby) }
        arguments = (positional + keywords).join(", ")
        signature = "    def #{op[:name]}: (#{arguments}) -> #{op[:into] ? return_type(into_type(op[:into])) : "untyped"}"
        return signature unless op[:paginate]

        element = paginate_element(op)
        "#{signature}\n    def #{op[:name]}_each: (#{arguments}) " \
          "?{ (#{element}) -> void } -> Enumerator[#{element}, void]"
      end
    end
  end
end
