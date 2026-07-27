# frozen_string_literal: true

require "yaml"
require "json"
require "rbconfig"
require_relative "runtime"

module Keiyaku
  # Every Ruby name the generator invents is decided here, so that a collision
  # is something one table can see rather than something each site discovers
  # separately — and so that a name Ruby will not accept is a refusal at
  # generation time rather than a SyntaxError at somebody's first require.
  module Names
    module_function

    IDENTIFIER = /\A[a-z_][a-zA-Z0-9_]*\z/

    KEYWORDS = %w[
      BEGIN END alias and begin break case class def defined do else elsif end ensure false for if in module
      next nil not or redo rescue retry return self super then true undef unless until when while yield __FILE__
      __LINE__ __ENCODING__
    ].freeze

    # Names the generated client needs for itself. `def class` is legal Ruby
    # and overrides the method every lookup in the runtime goes through, which
    # is a client that recurses until the stack ends rather than one that
    # fails to load.
    CLIENT_METHODS = (Keiyaku::Client.instance_methods(false) +
                      Keiyaku::Client.private_instance_methods(false) + %i[initialize]).map(&:to_s).freeze

    # A model's own contract: `with` and `to_h` are how a Data is used,
    # `deconstruct_keys` is how it pattern matches, `to_json_hash` is how it
    # becomes a request body, and `class` is how anything finds out what it
    # is. A property taking one of those names leaves the model unable to do
    # its job — unlike, say, one called `hash`, which plenty of real documents
    # have and which costs only the model's use as a Hash key.
    #
    # `members` is not among them. The runtime asks the class for its members
    # and never the instance, so a property of that name shadows a method
    # nothing calls — and GitHub's AppPermissions has one.
    MODEL_METHODS = %w[class with to_h deconstruct deconstruct_keys to_json to_json_hash].freeze

    # The constants the generated files actually spend, and no more. `Client`
    # is the class itself; `String` and the rest are what every other model's
    # fields are declared as, so a schema of that name would quietly change
    # what they cast to. A schema called `Range` or `File` shadows nothing
    # here — the generated code never mentions either — and refusing it would
    # be this table inventing a problem.
    CONSTANTS = %w[Client Keiyaku String Integer Float Time Date].freeze

    # `problem-details` and `problem_details` both want ProblemDetails, which
    # is a collision the caller has to hear about rather than a name to
    # invent a suffix for.
    def constant(name)
      const = name.to_s.split(/[^a-zA-Z0-9]+/).reject(&:empty?)
                  .map { |part| Keiyaku.camelize(part).sub(/\A./, &:upcase) }.join
      raise Impossible, "#{name.inspect} cannot be a Ruby constant" unless const.match?(/\A[A-Z][a-zA-Z0-9]*\z/)
      raise Impossible, "#{name.inspect} would be #{const}, which is spoken for" if CONSTANTS.include?(const)

      const
    end

    # Not called `method`, which would shadow the one every object has — the
    # kind of collision the rest of this table exists to refuse.
    def operation(name)
      # The separators have to become underscores before snake sees them: it
      # drops anything that is not a word character, which would run the
      # segments of a path together.
      ruby = Keiyaku.snake(name.to_s.gsub(/[^a-zA-Z0-9]+/, "_")).squeeze("_").delete_prefix("_").delete_suffix("_")
      raise Impossible, "#{name.inspect} cannot be a Ruby method name" unless ruby.match?(IDENTIFIER)
      raise Impossible, "#{name.inspect} is a Ruby keyword" if KEYWORDS.include?(ruby)
      raise Impossible, "#{name.inspect} is a method the client needs" if CLIENT_METHODS.include?(ruby)

      ruby
    end

    # A parameter becomes an argument of the generated method, which is a
    # local: it may shadow a method without harm, but it may not be a keyword,
    # since `def find(class:)` is a file Ruby will not read.
    def parameter(name)
      ruby = Keiyaku.snake(name)
      raise Impossible, "parameter #{name.inspect} cannot be a Ruby argument name" unless ruby.match?(IDENTIFIER)
      raise Impossible, "parameter #{name.inspect} is a Ruby keyword" if KEYWORDS.include?(ruby)

      ruby
    end

    # A field is a Data member, which is a method reached through a dot and a
    # Hash key written as a label. Both take a keyword: `{ end: String }` and
    # `range.end` are ordinary Ruby, and a date range is not an unusual shape
    # for a document to have. Only the names below are actually spent.
    #
    # A name Ruby will not take as an identifier keeps the one the document
    # gave it — GitHub counts its reactions in properties called `+1` and
    # `-1`. A Data member may be called that: it casts, round-trips, copies
    # with `with` and pattern matches as `in { "+1": n }`. The one thing it
    # cannot do is be reached through a dot, so `model["+1"]` is how it is
    # read, and the RBS types that rather than an attr_reader. Renaming it to
    # something dot-shaped would mean inventing a name the document never
    # used, which is the guess this generator exists not to make.
    #
    # The test is the first character rather than the result, because snake
    # drops what it cannot use: `+1` survives it as `1`, which is refused, but
    # `-1` survives as `_1`, which is a perfectly good identifier for a field
    # that has nothing to do with negative one. Both belong to the same
    # schema, and a model reading `rollup["+1"]` beside `rollup._1` would be
    # the generator having translated one of them and mangled the other.
    def field(name)
      ruby = Keiyaku.snake(name)
      return name.to_s if !name.match?(/\A[a-zA-Z_]/) || !ruby.match?(IDENTIFIER)
      raise Impossible, "property #{name.inspect} is a method the model needs" if MODEL_METHODS.include?(ruby)

      ruby
    end

    # Whether a field can be written as a bare label, in Ruby and in RBS both.
    def bare?(field) = field.match?(IDENTIFIER)
  end

  # Raised while translating something the generator cannot translate
  # faithfully. Caught per operation, where it becomes a refusal; raised while
  # building a component, it poisons that component and every operation that
  # reaches it.
  class Impossible < StandardError; end

  # Turns an OpenAPI document into three files: value types, a client, and RBS.
  #
  # The guiding rule is that anything it cannot translate faithfully becomes a
  # loud refusal rather than plausible-looking code.
  class Emitter
    Refusal = Struct.new(:operation, :reason)

    # One Data subclass to be emitted. `fields` maps the Ruby name to the Ruby
    # source for its type, `from` to the JSON name where the two differ. Being
    # a value, two of these built from the same schema compare equal, which is
    # what lets an inline schema appearing twice be emitted once.
    Model = Data.define(:fields, :required, :from)

    # Stamped on every file it writes: which generator, and which version of
    # the runtime contract the code was written against.
    HEADER = "# Generated by keiyaku #{VERSION}. Edits will be overwritten."

    # Where the runtime is, for the process that reads the generated files
    # back. Whether it is also an installed gem is not something to depend on.
    LIB = File.expand_path("..", __dir__)

    SCALARS = {
      %w[string date-time] => "Time",
      %w[string date] => "Date",
      %w[string binary] => "String",
      %w[string] => "String",
      %w[integer] => "Integer",
      %w[number] => "Float",
      %w[boolean] => ":bool"
    }.freeze

    # OpenAPI describes no pagination, so there is nothing to detect: guessing
    # from parameter names called `page` or `cursor` would produce a client
    # that loops wrongly and silently. The document has to say so itself, in
    # an x-keiyaku-paginate extension on the operation.
    PAGINATION = %w[offset page cursor link].freeze

    attr_reader :refusals, :notes

    def initialize(path, namespace:)
      @spec = path.end_with?(".json") ? JSON.parse(File.read(path)) : YAML.load_file(path)
      @namespace = namespace
      @models = {}      # constant name => args for Keiyaku.model(...), or union source
      @unions = {}      # union source => its RBS expansion, e.g. "Dog | Cat"
      @deps = {}        # constant name => referenced constant names
      @poisoned = {}    # constant name => why nothing may be typed as it
      @refusals = []
      @notes = []
    end

    # The generated files, and whether Ruby could read them back. Anything
    # already written stays on disk: reading the file the generator could not
    # load is how its remaining mistakes get found.
    attr_reader :broken

    def emit(dir, verify: true)
      collect_models
      operations = collect_operations
      File.write(File.join(dir, "types.rb"), types_source)
      File.write(File.join(dir, "client.rb"), client_source(operations))
      File.write(File.join(dir, "#{Keiyaku.snake(@namespace)}.rbs"), rbs_source(operations))
      @broken = verify ? load_check(dir) : nil
      operations
    end

    private

    # Only the document in hand. A `$ref` into another file is not a narrower
    # case of this one: taking the last segment of `common.yaml#/Pet` would
    # name the local Pet, and the client would then load, run, and decode one
    # schema as another. Bundle the document first; this says so rather than
    # guessing what was in the file it cannot see.
    def pointer(ref)
      raise Impossible, "$ref #{ref.inspect} is not local to this document; bundle it first" unless ref.start_with?("#/")

      ref.delete_prefix("#/").split("/").reduce(@spec) do |doc, key|
        # ~1 and ~0 are how a JSON Pointer spells / and ~, which a path
        # template in `#/paths/~1pets/get` is full of.
        key = key.gsub("~1", "/").gsub("~0", "~")
        raise Impossible, "$ref #{ref.inspect} does not resolve" unless doc.is_a?(Hash) && doc.key?(key)

        doc[key]
      end
    end

    def resolve(node)
      node.is_a?(Hash) && node["$ref"] ? pointer(node["$ref"]) : node
    end

    # The constant a `$ref` names, having checked that there is something at
    # the other end of it and that nothing has spoiled the name.
    def const_for(ref)
      pointer(ref)
      const = Names.constant(ref.split("/").last.gsub("~1", "/").gsub("~0", "~"))
      raise Impossible, @poisoned[const] if @poisoned.key?(const)

      const
    end

    # --- schemas ------------------------------------------------------------

    def collect_models
      schemas = @spec.dig("components", "schemas") || {}

      # Two schemas wanting one constant is settled before either is built:
      # whichever came second would otherwise replace the first, and every
      # operation typed as the first would go on being generated against a
      # model that is no longer there.
      names = {}
      schemas.each_key do |name|
        const = begin
          Names.constant(name)
        rescue Impossible => e
          # Nothing can refer to it either, so whatever does gets the same
          # message where it can be acted on: against the operation.
          next @notes << "schema #{name.inspect} is not emitted: #{e.message}"
        end

        if (first = names[const])
          poison(const, "schemas #{first.inspect} and #{name.inspect} both map to #{const}")
        else
          names[const] = name
        end
      end

      schemas.each do |name, schema|
        const = names.key(name) or next
        next if @poisoned.key?(const)

        begin
          define_model(const, schema)
        rescue Impossible => e
          poison(const, "#{const}: #{e.message}")
        end
      end

      spread_poison
    end

    # A component nothing may be typed as. It is a note as well as a poison,
    # because the operation that gets refused for reaching it is refused two
    # models further down, and would otherwise be the only thing said about a
    # schema whose own problem is never mentioned.
    def poison(const, reason)
      @notes << reason
      @poisoned[const] = reason
    end

    # A model built out of a poisoned one is poisoned too, however far down the
    # chain it sits, so that no operation is typed as something types.rb does
    # not go on to define.
    def spread_poison
      loop do
        spread = @deps.filter_map do |const, deps|
          next if @poisoned.key?(const)

          culprit = deps.find { @poisoned.key?(_1) }
          [const, "#{const} is built from #{culprit}, which was refused"] if culprit
        end
        break if spread.empty?

        @poisoned.merge!(spread.to_h)
      end

      @poisoned.each_key { @models.delete(_1) }
    end

    # `upload:` is set while translating a multipart body, where a binary
    # string means a file rather than a String.
    def define_model(const, schema, upload: false)
      schema = merge_all_of(schema)

      # A component that is itself a union is not a Data subclass; it is a
      # constant holding the union, so that a $ref to it still resolves.
      if schema["oneOf"] || schema["anyOf"]
        deps = []
        source = collapse_union(schema, const, deps)
        expansion = source ? rbs_type(source) : nil
        source, expansion = union_for(schema, const, deps) unless source

        @models[const] = source
        @unions[const] = expansion
        @deps[const] = deps.uniq - [const]
        return
      end

      # Nor is a component that is not an object at all. GitHub has ninety-odd
      # — `author-association` is a string with an enum, `alert-number` an
      # integer — and a Data with no fields casts nothing, so a $ref to one
      # produced a client that loaded, typechecked, and then raised on the
      # first response that carried the field. It becomes the type it says it
      # is, the way the union branch above becomes the union it is.
      kind = schema["type"]
      kind = kind - ["null"] if kind.is_a?(Array)
      unless kind.nil? || Array(kind).include?("object") || schema["properties"]
        deps = []
        # An array component and the object inside it are two types, and the
        # document named only one of them. Hoisting the element under the
        # component's own name gets `Widgets = [Widgets]`, so the element is
        # named for being the element.
        context = Array(kind).include?("array") ? "#{const} item" : const
        source = type_for(schema, context, deps)
        @models[const] = source
        @unions[const] = rbs_type(source)
        @deps[const] = deps.uniq - [const]
        return
      end

      deps = []
      @models[const] = build_model(const, schema, deps, upload:)
      @deps[const] = deps.uniq - [const]
    end

    # Builds the model without deciding what it is called, so that a caller can
    # compare it against the ones already emitted.
    def build_model(const, schema, deps, upload: false)
      declared = schema["required"] || []
      fields, required, from, seen = {}, [], {}, {}

      (schema["properties"] || {}).each do |json_name, property|
        field = Names.field(json_name)
        # Keeping the first would leave a model that quietly drops a property
        # the document declares, and a request body missing a field the caller
        # thought they had set.
        if (first = seen[field])
          raise Impossible, "properties #{first.inspect} and #{json_name.inspect} both become #{field}"
        end

        seen[field] = json_name
        fields[field] = type_for(property, "#{const}.#{field}", deps, upload:)
        required << field if declared.include?(json_name)
        from[field] = json_name if Keiyaku.camelize(field) != json_name
      end

      Model.new(fields:, required:, from:)
    end

    def merge_all_of(schema)
      return schema unless schema["allOf"]

      schema["allOf"].map { merge_all_of(resolve(_1)) }.reduce(schema.except("allOf")) do |acc, part|
        acc.merge(part) do |key, a, b|
          case key
          when "properties" then a.merge(b)
          when "required" then a | b
          else b
          end
        end
      end
    end

    # Returns Ruby source for a type, recording model dependencies as it goes.
    def type_for(schema, context, deps, upload: false)
      return ":any" if schema.nil? || schema.empty?

      if (ref = schema["$ref"])
        const = const_for(ref)
        deps << const
        return const
      end

      schema = merge_all_of(schema) if schema["allOf"]

      if schema["oneOf"] || schema["anyOf"]
        collapsed = collapse_union(schema, context, deps)
        return collapsed if collapsed

        source, expansion = union_for(schema, context, deps)
        @unions[source] = expansion unless source == ":any"
        return source
      end

      # `type: [string, null]` is 3.1's other way of saying a field may be
      # null, and means the same as the `anyOf` spelling collapsed above: the
      # field is a string. More than one type left after dropping null is a
      # real union with nothing to dispatch on, so it falls through to :any
      # rather than picking whichever came first.
      kind = schema["type"]
      if kind.is_a?(Array) && (rest = kind - ["null"]).size == 1
        kind = rest.first
      end

      case kind
      when "array"
        # A tuple — `items` as a list in draft-07, `prefixItems` in 2020-12 —
        # is a fixed-length heterogeneous array, which one element type cannot
        # describe. Taking the first element's type would be a guess.
        if schema["items"].is_a?(Array) || schema["prefixItems"]
          @notes << "#{context}: a tuple, typed as [:any]"
          return "[:any]"
        end

        # An array of files is a real multipart shape, so `upload:` carries
        # into the items — but not into a nested object, where a part is JSON
        # and a file would be meaningless.
        "[#{type_for(schema["items"] || {}, "#{context}[]", deps, upload:)}]"
      when "object", nil
        if (additional = schema["additionalProperties"]).is_a?(Hash)
          "{ String => #{type_for(additional, "#{context}{}", deps)} }"
        elsif schema["properties"]
          hoist(context, schema, deps)
        else
          ":any"
        end
      else
        format = [kind, schema["format"]].compact
        if upload && format == %w[string binary]
          ":upload"
        else
          SCALARS[format] || SCALARS[[kind]] || ":any"
        end
      end
    end

    # Two shapes that are unions only on paper. `anyOf: [{type: string},
    # {type: null}]` is how OpenAPI 3.1 says a field may be null — the field is
    # a string — and a union whose branches all resolve to one type says
    # nothing that type does not. Neither is a guess: there is exactly one type
    # in it. Returns nil when the union is a real one.
    def collapse_union(schema, context, deps)
      variants = (schema["oneOf"] || schema["anyOf"]).reject { _1["type"] == "null" }
      return nil if variants.empty?
      return type_for(variants.first, context, deps) if variants.size == 1

      # With more than one left, deciding means translating them all, so this
      # only looks at branches that cannot hoist a model — otherwise comparing
      # them could leave behind a type nothing goes on to name.
      return nil unless variants.all? { _1.key?("$ref") || SCALARS.key?([_1["type"]]) }

      scratch = []
      sources = variants.map { type_for(_1, context, scratch) }
      return nil unless sources.uniq.size == 1

      deps.concat(scratch)
      sources.first
    end

    # A union translates only when the document says how to tell the variants
    # apart. Casting by trying each one until something sticks is exactly the
    # plausible-but-wrong behaviour this generator exists to avoid, so an
    # undiscriminated union stays :any and says why.
    #
    # Returns the Ruby source and the RBS that describes it.
    def union_for(schema, context, deps)
      keyword = schema["oneOf"] ? "oneOf" : "anyOf"
      variants = schema[keyword]
      property = schema.dig("discriminator", "propertyName")

      complaint =
        if property.nil? then "no discriminator"
        elsif !variants.all? { _1.key?("$ref") } then "a variant written inline"
        end
      if complaint
        @notes << "#{context}: #{keyword} with #{complaint}, typed as :any"
        return [":any", "untyped"]
      end

      consts = variants.map { const_for(_1["$ref"]) }
      # A mapping's value is either a $ref or the bare name of a schema in
      # components, which the specification allows and documents use.
      mapping = (schema["discriminator"]["mapping"] || {}).map do |value, ref|
        [value, const_for(ref.include?("/") ? ref : "#/components/schemas/#{ref}")]
      end
      deps.concat(consts + mapping.map(&:last))

      args = [*consts, "on: #{property.inspect}"]
      args << "map: { #{mapping.map { |value, const| "#{value.inspect} => #{const}" }.join(", ")} }" if mapping.any?
      ["Keiyaku::OneOf[#{args.join(", ")}]", (consts + mapping.map(&:last)).uniq.join(" | ")]
    end

    # An inline object gets its own type rather than degrading to a bare Hash,
    # named for where it appeared. A document that writes the same schema out
    # again under every operation — which is what one with no components looks
    # like — would otherwise get a model per copy, so an identical model that
    # has already been emitted is used instead of a second one.
    def hoist(context, schema, deps, upload: false)
      const = Names.constant(context.split(/[.\[\]{}]/).reject(&:empty?).join("_"))
      own = []
      model = build_model(const, merge_all_of(schema), own, upload:)

      if (existing = @models.key(model))
        deps << existing
        return existing
      end

      # Typing it :any instead would leave the caller a Hash where the
      # document describes a shape, and no way to tell which of the two
      # schemas the name ended up meaning.
      raise Impossible, "#{const} already names a different schema" if @models.key?(const) || @poisoned.key?(const)

      @models[const] = model
      @deps[const] = own.uniq - [const]
      deps << const
      const
    end

    # --- operations ---------------------------------------------------------

    def collect_operations
      if @spec.dig("servers", 0, "url").to_s.empty?
        @notes << "no servers declared; a client has to be built with base_url:"
      end

      collect_security

      operations = (@spec["paths"] || {}).flat_map do |template, path_item|
        begin
          path_item = resolve(path_item)
        rescue Impossible => e
          # There is no operation to refuse yet — the verbs are on the other
          # side of the $ref — so the path goes in the report whole.
          @refusals << Refusal.new(template, e.message)
          next []
        end

        path_item.slice("get", "put", "post", "delete", "patch", "head", "options").map do |verb, op|
          build_operation(verb, template, op, path_item["parameters"] || [])
        end
      end

      # Two operations landing on one name is not a note: whichever the
      # generator wrote second would take the method, and every call meant for
      # the other would go somewhere else entirely. Neither is emitted, and the
      # document has to say which is which.
      operations.group_by { _1[:name] }.each do |name, group|
        next if group.size == 1

        reason = "#{group.size} operations map to this name (#{group.map { "#{_1[:verb].upcase} #{_1[:template]}" }.join(", ")})"
        @refusals << Refusal.new(name, reason)
        group.each { _1.replace(name:, unsupported: reason) }
      end

      operations.uniq { _1[:unsupported] ? _1[:name] : _1.object_id }
    end

    # --- security -----------------------------------------------------------

    # The schemes the document declares, in the runtime's own vocabulary. One
    # nobody can implement is kept out of the table rather than out of the
    # document: it only costs the operations that actually require it.
    def collect_security
      @schemes = {}
      @unsupported_schemes = {}

      (@spec.dig("components", "securitySchemes") || {}).each do |name, scheme|
        scheme = resolve(scheme)
        if (declaration = security_declaration(scheme))
          @schemes[name] = declaration
        else
          @unsupported_schemes[name] = [scheme["type"], scheme["scheme"]].compact.join(" ")
        end
      end

      @default_security = requirement_for(@spec["security"])
      # What an operation that says nothing about security gets. An
      # alternative naming a scheme nothing can send is not one of them, and
      # the operations that are left with none are refused one by one below.
      @default_usable = (@default_security || []).select { |schemes| schemes.all? { @schemes.key?(_1) } }
    end

    def security_declaration(scheme)
      case [scheme["type"], scheme["scheme"]&.downcase, scheme["in"]]
      in ["http", "bearer", _] then ":bearer"
      in ["http", "basic", _] then ":basic"
      # An OAuth 2 access token is a bearer token, and so is the one an
      # OpenID Connect flow ends with; where it goes on the request is RFC
      # 6750 rather than a guess. Obtaining it is the caller's business —
      # nothing here runs a flow, which is also why the scopes a requirement
      # lists say nothing this client could act on.
      in ["oauth2" | "openIdConnect", _, _] then ":bearer"
      in ["apiKey", _, "header"] then "{ header: #{scheme["name"].inspect} }"
      in ["apiKey", _, "query"] then "{ query: #{scheme["name"].inspect} }"
      in ["apiKey", _, "cookie"] then "{ cookie: #{scheme["name"].inspect} }"
      else nil
      end
    end

    # A security requirement is a list of alternatives, any one of which is
    # enough, each naming schemes that all have to be satisfied. `security: []`
    # is the operation that takes no credentials, which is not the same as the
    # key being absent — that one takes the document's.
    def requirement_for(declared) = declared&.map(&:keys)

    # What one operation actually requires, with the alternatives the client
    # could not satisfy dropped. Only when none are left is the operation
    # refused: an operation that documents mutualTLS *or* an API key is one
    # this client can still call.
    def security_for(name, op)
      alternatives = op.key?("security") ? requirement_for(op["security"]) : @default_security
      return [] if alternatives.nil? || alternatives.empty?

      usable, rejected = alternatives.partition { |schemes| schemes.all? { @schemes.key?(_1) } }

      rejected.each do |schemes|
        unknown = schemes.reject { @schemes.key?(_1) || @unsupported_schemes.key?(_1) }
        raise Impossible, "requires #{unknown.first.inspect}, which the document does not declare" if unknown.any?
      end

      if usable.empty?
        needed = rejected.flatten.uniq.map { "#{_1} (#{@unsupported_schemes[_1]})" }
        raise Impossible, "requires #{needed.join(" or ")}, which the runtime has no way to send"
      end
      if rejected.any?
        @notes << "#{name}: sends #{usable.first.join(" and ")}; " \
                  "the document also allows #{rejected.map { _1.join(" and ") }.join(" or ")}, which is not supported"
      end

      usable
    end

    # The shortest spelling of a requirement: a bare scheme name where there is
    # one alternative naming one scheme, `false` where there is no requirement
    # at all, and the alternatives written out where there is a choice.
    def requirement_source(alternatives)
      return "false" if alternatives.empty?
      return alternatives.first.first.to_sym.inspect if alternatives.size == 1 && alternatives.first.size == 1

      "[#{alternatives.map { |schemes| "[#{schemes.map { _1.to_sym.inspect }.join(", ")}]" }.join(", ")}]"
    end

    # Emitted on an operation only where it differs from the client's default,
    # which is the document's own root requirement.
    def security_source(alternatives)
      requirement_source(alternatives) unless alternatives == @default_usable
    end

    # An operationId is optional, and plenty of documents that a server
    # generates from its own routes carry none, so the verb and the path are
    # all there is to go on. A path parameter becomes `by_x`, which keeps
    # GET /pet and GET /pet/{petId} from arriving at the same method.
    def operation_name(verb, template, op)
      Names.operation(op["operationId"] || "#{verb}_#{template.gsub(/\{(\w+)\}/) { "by_#{$1}" }}")
    end

    def build_operation(verb, template, op, inherited_params)
      label = op["operationId"] || "#{verb.upcase} #{template}"
      begin
        name = operation_name(verb, template, op)
      rescue Impossible => e
        # Without a name there is nothing to declare, not even a stub: an
        # `unsupported :class` would define the method that breaks the client.
        @refusals << Refusal.new(label, e.message)
        return { name: nil, label:, unsupported: e.message }
      end

      translate(verb, template, op, inherited_params, name)
    rescue Impossible => e
      @refusals << Refusal.new(name, e.message)
      { name:, unsupported: e.message }
    end

    def translate(verb, template, op, inherited_params, name)
      deps = []
      params = (inherited_params + (op["parameters"] || [])).map { resolve(_1) }
      query, header, types = [], {}, {}

      params.each do |param|
        style = param["style"] || (param["in"] == "query" ? "form" : "simple")
        explode = param.fetch("explode", style == "form")
        types[param["name"]] = type_for(param["schema"] || {}, "#{name}_#{Keiyaku.snake(param["name"])}", deps)

        case param["in"]
        when "path"
          raise Impossible, "path parameter #{param["name"]} uses style=#{style}" unless style == "simple"
        when "query"
          raise Impossible, "query parameter #{param["name"]} uses style=#{style}" unless style == "form"
          raise Impossible, "query parameter #{param["name"]} uses explode=false" unless explode

          query << "#{param["name"]}#{"!" if param["required"]}"
        when "header"
          header[param["name"]] = "#{Names.parameter(param["name"])}#{"!" if param["required"]}"
        else
          raise Impossible, "#{param["in"]} parameters are not supported"
        end
      end

      hint = op["x-keiyaku-paginate"]
      if hint && (problem = pagination_problem(hint, query))
        raise Impossible, "x-keiyaku-paginate: #{problem}"
      end

      body = form = multipart = content_type = nil
      if (request_body = resolve(op["requestBody"]))
        content = request_body["content"] || {}
        json = content.keys.find { _1.include?("json") }
        binary = content.keys.find { _1 == "application/octet-stream" || content[_1].dig("schema", "format") == "binary" }

        if json
          body = type_for(content[json]["schema"], "#{name}_body", deps)
        elsif content.key?("application/x-www-form-urlencoded")
          form = type_for(content["application/x-www-form-urlencoded"]["schema"], "#{name}_body", deps)
        elsif content.key?("multipart/form-data")
          multipart = multipart_type(content["multipart/form-data"]["schema"] || {}, "#{name}_body", deps)
        elsif binary
          body = ":binary"
          content_type = binary
        else
          raise Impossible, "request body is #{content.keys.join(", ")}"
        end
      end

      # The method's own arguments, which is where two parameter names that
      # normalise to one show up: Ruby would take `foo-bar` and `foo_bar` as
      # one keyword written twice, and refuse to parse the file.
      arguments = template.scan(/\{(\w+)\}/).flatten.map { Names.parameter(_1) }
      arguments << "body" if body || form || multipart
      arguments += query.map { Names.parameter(_1.delete_suffix("!")) } + header.values.map { _1.delete_suffix("!") }
      if (duplicate = arguments.tally.find { |_, count| count > 1 })
        raise Impossible, "two of its parameters are both called #{duplicate.first}"
      end

      into, errors = responses(op, name, deps)

      { name:, verb:, template:, query:, header:, types:, body:, form:, multipart:, content_type:, into:,
        errors:, hint:, paginate: (hint && hash_source(hint)),
        security: security_source(security_for(name, op)), summary: op["summary"], deps: }
    end

    # One method has one return type, so several success responses have to
    # agree on it. Where they do not, the alternative to refusing is a method
    # that casts a 202's job into the 200's user and hands back a model whose
    # every field is nil.
    def responses(op, name, deps)
      into, errors, success = nil, {}, {}

      (op["responses"] || {}).each do |status, response|
        content = resolve(response)["content"] || {}
        json = content.keys.find { _1.include?("json") }
        schema = json && content[json]["schema"]

        if !status.to_i.between?(200, 299)
          errors[status == "default" ? ":default" : status] = type_for(schema, "#{name}_error", deps) if schema
        elsif schema
          # Later ones are named for their status, so that two which turn out
          # to be the same shape still dedupe onto the first's name, and two
          # which do not are told apart by the message that refuses them.
          success[status] = type_for(schema, "#{name}#{"_#{status}" if success.any?}_result", deps)
        elsif content.any?
          @notes << "#{name}: #{status} is #{content.keys.join(", ")}, which is returned as the raw body"
        end
      end

      if success.values.uniq.size > 1
        raise Impossible, "its success responses do not agree on a type " \
                          "(#{success.map { |status, type| "#{status} is #{type}" }.join(", ")})"
      end

      [success.values.first, errors]
    end

    # A hint that names a parameter the operation does not have would produce a
    # client that pages forever, so it is refused like any other construct that
    # cannot be honoured.
    def pagination_problem(hint, query)
      by = hint["by"].to_s
      names = query.map { _1.delete_suffix("!") }

      if !PAGINATION.include?(by)
        "unknown strategy #{hint["by"].inspect}, expected one of #{PAGINATION.join(", ")}"
      elsif (wrong = %w[param size].find { hint[_1] && !names.include?(hint[_1]) })
        "#{wrong} #{hint[wrong].inspect} is not a query parameter of this operation"
      elsif by != "link" && hint["param"].nil?
        "by: #{by} needs the name of the parameter to advance"
      elsif by == "cursor" && hint["next"].nil?
        "by: cursor needs the response field the next cursor comes from"
      end
    end

    def hash_source(hint)
      "{ #{hint.map { |key, value| "#{key}: #{key == "by" ? ":#{value}" : value.inspect}" }.join(", ")} }"
    end

    # A multipart body always gets its own type, even where the document points
    # at a shared component: `format: binary` means a file here and a plain
    # string everywhere else, and one model cannot mean both.
    def multipart_type(schema, context, deps)
      schema = merge_all_of(resolve(schema))
      return type_for(schema, context, deps) unless schema["properties"]

      hoist(context, schema, deps, upload: true)
    end

    # --- output -------------------------------------------------------------

    # The generator has no business trusting what it just wrote. A constant
    # that turned out to be a local variable, a method named for a keyword, a
    # type referring to a model that never got emitted: none of those are
    # visible in the document, and all of them are visible the moment Ruby
    # reads the file back. This is the last place they can be reported against
    # the document rather than against a stack trace at somebody's first call.
    #
    # It runs in another process, because loading the client here would mean
    # the generator's own namespace, and instantiates it, because a method
    # named for one the client needs is a file that loads and then recurses.
    def load_check(dir)
      script = <<~RUBY
        require #{File.expand_path(File.join(dir, "client")).inspect}
        #{@namespace}::Client.new(base_url: "https://keiyaku.invalid")
      RUBY
      output = IO.popen([RbConfig.ruby, "-I", LIB, "-e", script], err: %i[child out], &:read)
      $?.success? ? nil : output.strip
    end

    def sorted_models
      ordered, seen = [], {}
      visit = lambda do |const|
        return if seen[const]

        seen[const] = :visiting
        @deps.fetch(const, []).each { |dep| visit.(dep) unless seen[dep] == :visiting }
        seen[const] = true
        ordered << const
      end
      @models.each_key { visit.(_1) }
      ordered
    end

    # The fields go in a Hash of their own rather than as keywords beside
    # `required:` and `from:`, because they are the API's names and not ours:
    # a DIDComm message has a property called `from`.
    # A field that is not an identifier is still a Hash label, in quotes:
    # `{ "+1": Integer }` is the same Hash as `{ :"+1" => Integer }`.
    def label(field) = Names.bare?(field) ? field : field.inspect

    def model_options(model)
      options = []
      options << "required: %i[#{model.required.join(" ")}]" if model.required.any?
      options << "from: { #{model.from.map { |field, json| "#{label(field)}: #{json.inspect}" }.join(", ")} }" if model.from.any?
      options
    end

    # A schema that contains itself — a tree with child nodes, two models that
    # name each other — cannot be written as the constant it is in the middle
    # of defining. The runtime calls a Proc for the type the first time it
    # casts one, which is late enough for the constant to exist.
    def lazily(source, defined)
      referenced = source.scan(/[A-Z][a-zA-Z0-9]*/).uniq & @models.keys
      referenced.all? { defined.include?(_1) } ? source : "-> { #{source} }"
    end

    def types_source
      defined = []
      lines = sorted_models.map do |const|
        model = @models[const]
        defined << const
        next "  #{const} = #{model}" if model.is_a?(String)

        fields = model.fields.map { |field, type| "#{label(field)}: #{lazily(type, defined - [const])}" }
        options = model_options(model).map { ", #{_1}" }.join
        one_line = "  #{const} = Keiyaku.model({ #{fields.join(", ")} }#{options})"
        next one_line if one_line.length <= 110

        "  #{const} = Keiyaku.model({\n    #{fields.join(",\n    ")}\n  }#{options})"
      end

      <<~RUBY
        # frozen_string_literal: true
        #{HEADER}

        require "keiyaku/runtime"

        module #{@namespace}
        #{lines.join("\n")}
        end
      RUBY
    end

    def client_source(operations)
      lines = operations.map do |op|
        next "    # cannot be generated: #{op[:label]}: #{op[:unsupported]}" if op[:name].nil?
        next "    unsupported :#{op[:name]}, #{op[:unsupported].inspect}" if op[:unsupported]

        args = [":#{op[:name]}", op[:template].inspect]
        args << "query: %i[#{op[:query].join(" ")}]" if op[:query].any?
        args << "header: { #{op[:header].map { |json, ruby| "#{json.inspect} => :#{ruby}" }.join(", ")} }" if op[:header].any?
        args << "body: #{op[:body]}" if op[:body]
        args << "form: #{op[:form]}" if op[:form]
        args << "multipart: #{op[:multipart]}" if op[:multipart]
        args << "content_type: #{op[:content_type].inspect}" if op[:content_type]
        args << "into: #{op[:into]}" if op[:into]
        args << "errors: { #{op[:errors].map { |status, type| "#{status} => #{type}" }.join(", ")} }" if op[:errors].any?
        args << "paginate: #{op[:paginate]}" if op[:paginate]
        args << "security: #{op[:security]}" if op[:security]

        "    #{op[:verb].ljust(6)} #{args.join(", ")}"
      end

      <<~RUBY
        # frozen_string_literal: true
        #{HEADER}

        require_relative "types"

        module #{@namespace}
          class Client < Keiyaku::Client
            server #{@spec.dig("servers", 0, "url").inspect}
        #{security_table}
        #{lines.join("\n")}
          end
        end
      RUBY
    end

    # The schemes the whole document has, and the requirement that holds
    # wherever an operation does not state one of its own. Both belong to the
    # client rather than to any of its methods.
    def security_table
      return "" if @schemes.empty?

      table = @schemes.map { |name, declaration| "#{scheme_key(name)} #{declaration}" }
      default = @default_usable.empty? ? "" : ", default: #{requirement_source(@default_usable)}"
      "    security({ #{table.join(", ")} }#{default})\n"
    end

    # The document's own name for the scheme, which is what credentials are
    # given by, so it is left exactly as the document spells it.
    def scheme_key(name)
      name.match?(/\A[a-zA-Z_][a-zA-Z0-9_]*\z/) ? "#{name}:" : "#{name.inspect}:"
    end

    RBS_SCALARS = {
      ":bool" => "bool", ":any" => "untyped", ":binary" => "String",
      ":upload" => "Keiyaku::Upload | IO"
    }.freeze

    def rbs_type(source)
      # A recursive type is written as a Proc in the source and as itself here:
      # RBS has no trouble with a class that mentions its own name.
      return rbs_type(source[/\A-> \{(.*)\}\z/m, 1].strip) if source.start_with?("-> {")
      return "Array[#{rbs_type(source[1..-2].strip)}]" if source.start_with?("[")
      return "Hash[String, #{rbs_type(source[/=>(.*)}/m, 1].strip)}]" if source.start_with?("{")

      # A named union is referred to by its alias; an inline one is spelled out.
      if (expansion = @unions[source])
        return source.start_with?("Keiyaku::OneOf[") ? expand_union(expansion) : Keiyaku.snake(source)
      end

      RBS_SCALARS[source] || source
    end

    # A union is written bare everywhere but one place: RBS reads `|` after a
    # return type as the start of another overload, so `-> A | B` is a syntax
    # error where `attr_reader a: A | B` is fine. Only a top-level `|` needs
    # the parentheses — inside `Array[...]` the brackets already close it off.
    def rbs_return(type)
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

    # What the enumerator yields: the element of the array being paged over,
    # which is either the response itself or a field of the envelope.
    def paginate_element(op)
      source = op[:into]
      if (items = op[:hint]["items"])
        model = @models[source]
        return "untyped" unless model.is_a?(Model)

        source = model.fields[Keiyaku.snake(items)]
      end

      source.to_s.start_with?("[") ? rbs_type(source[1..-2].strip) : "untyped"
    end

    # RBS has no constant that stands for a union, so a union component becomes
    # a type alias for signatures to use, plus the constant itself for callers
    # that reach for `Event.cast`.
    def union_rbs(const)
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

    def rbs_source(operations)
      models = sorted_models.map do |const|
        model = @models[const]
        next union_rbs(const) if model.is_a?(String)

        # `attr_reader "+1":` is not RBS, in either spelling — the name is not
        # a method, so it is typed where it is actually read instead.
        bare, quoted = model.fields.partition { |field, _| Names.bare?(field) }
        declared = lambda do |field, type|
          "#{rbs_type(type)}#{"?" unless model.required.include?(field)}"
        end

        readers = bare.map { |field, type| "    attr_reader #{field}: #{declared.(field, type)}" }
        unless quoted.empty?
          overloads = quoted.map { |field, type| "(#{field.inspect}) -> #{declared.(field, type)}" }
          readers << "    def []: #{overloads.join("\n           | ")}"
        end
        <<~RBS.chomp
            class #{const} < ::Data
          #{readers.join("\n")}
              def self.cast: (untyped, ?String) -> #{const}
              def to_json_hash: () -> Hash[String, untyped]
            end
        RBS
      end

      methods = operations.filter_map do |op|
        next if op[:name].nil?
        next "    def #{op[:name]}: (*untyped) -> bot  # not generated: #{op[:unsupported]}" if op[:unsupported]

        types = op[:types]
        positional = op[:template].scan(/\{(\w+)\}/).flatten.map do |param|
          "#{rbs_type(types[param] || ":any")} #{Keiyaku.snake(param)}"
        end
        payload = op[:body] || op[:form] || op[:multipart]
        positional << "#{rbs_type(payload)} body" if payload

        keyword = lambda do |json_name, declared|
          required = declared.end_with?("!")
          type = rbs_type(types[json_name] || ":any")
          "#{"?" unless required}#{Keiyaku.snake(declared.delete_suffix("!"))}: #{type}#{"?" unless required}"
        end
        keywords = op[:query].map { keyword.(_1.delete_suffix("!"), _1) } +
                   op[:header].map { |json, ruby| keyword.(json, ruby) }
        arguments = (positional + keywords).join(", ")
        signature = "    def #{op[:name]}: (#{arguments}) -> #{op[:into] ? rbs_return(rbs_type(op[:into])) : "untyped"}"
        next signature unless op[:paginate]

        element = paginate_element(op)
        "#{signature}\n    def #{op[:name]}_each: (#{arguments}) " \
          "?{ (#{element}) -> void } -> Enumerator[#{element}, void]"
      end

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
  end
end
