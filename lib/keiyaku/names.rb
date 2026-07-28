# frozen_string_literal: true

require_relative "runtime"

module Keiyaku
  # Raised while translating something the generator cannot translate
  # faithfully. Caught per operation, where it becomes a refusal; raised while
  # building a component, it poisons that component and every operation that
  # reaches it.
  class Impossible < StandardError; end

  # Every Ruby name the generator invents is decided here, so that a collision
  # is something one table can see rather than something each site discovers
  # separately — and so that a name Ruby will not accept is a refusal at
  # generation time rather than a SyntaxError at somebody's first require.
  module Names
    module_function

    IDENTIFIER = /\A[a-z_][a-zA-Z0-9_]*\z/

    # KEYWORDS is Keiyaku's rather than this table's, because the runtime
    # needs the same list: a parameter may be named for one, and the generated
    # method body then has to read it back out of its binding.

    # Names the generated client needs for itself. `def class` is legal Ruby
    # and overrides the method every lookup in the runtime goes through, which
    # is a client that recurses until the stack ends rather than one that
    # fails to load.
    CLIENT_METHODS = (Keiyaku::Client.instance_methods(false) +
                      Keiyaku::Client.private_instance_methods(false) + %i[initialize]).map(&:to_s).freeze

    # A model's own contract: `with` and `to_h` are how a value type is used,
    # `deconstruct_keys` is how it pattern matches, `to_json_hash` is how it
    # becomes a request body, and `class` is how anything finds out what it
    # is. A property taking one of those names leaves the model unable to do
    # its job — unlike, say, one called `hash`, which plenty of real documents
    # have and which costs only the model's use as a Hash key.
    #
    # The properties a document allows but does not name are read through the
    # same `[]` that reads a declared one, so a model open to them spends no
    # name here that a closed one does not — a reader called `extra` would
    # have cost this table a word that real documents use as a property.
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

    # The module the generated files declare. It is the caller's word rather
    # than the document's, so what this catches is a `--module` that would
    # become three files Ruby cannot read — reported against the flag that
    # asked for it rather than as the generator blaming itself in the load
    # check. One constant and no more: `module Acme::Api` needs an Acme that
    # nothing here defines, and is a NameError at the first require.
    def namespace(name)
      unless name.to_s.match?(/\A[A-Z][a-zA-Z0-9]*\z/)
        raise Impossible, "#{name.inspect} cannot be the module the generated files declare; " \
                          "it has to be one Ruby constant, like Petstore"
      end

      name.to_s
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
    # local: it may shadow a method without harm. A keyword it may be too,
    # but only where the argument is one — `def find(until: nil)` is a method
    # Ruby will define and `def find(until)` is a file it will not read. So a
    # query or header parameter keeps the document's name and the runtime
    # reads it out of the binding, and a path parameter, which is positional
    # because a URL's segments are ordered, is refused.
    def parameter(name, positional: false)
      ruby = Keiyaku.snake(name)
      raise Impossible, "parameter #{name.inspect} cannot be a Ruby argument name" unless ruby.match?(IDENTIFIER)
      if positional && KEYWORDS.include?(ruby)
        raise Impossible, "path parameter #{name.inspect} is a Ruby keyword, which a positional argument cannot be"
      end

      ruby
    end

    # A field is a model's member, which is a method reached through a dot and
    # a Hash key written as a label. Both take a keyword: `{ end: String }`
    # and `range.end` are ordinary Ruby, and a date range is not an unusual
    # shape for a document to have. Only the names below are actually spent.
    #
    # A name Ruby will not take as an identifier keeps the one the document
    # gave it — GitHub counts its reactions in properties called `+1` and
    # `-1`. A member may be called that: it casts, round-trips, copies
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
end
