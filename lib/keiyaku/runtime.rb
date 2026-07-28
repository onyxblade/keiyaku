# frozen_string_literal: true

require "json"
require "uri"
require "time"
require "date"
require "securerandom"
require "socket"
require "timeout"
require_relative "version"

# A runtime for generated OpenAPI clients.
#
# Everything that is identical across every API lives here; the generated code
# carries only what is specific to one API. The contract between the two is a
# single method, Client#__invoke, plus Keiyaku.model.
module Keiyaku
  UNSET = Object.new
  def UNSET.inspect = "Keiyaku::UNSET"
  UNSET.freeze

  class Error < StandardError; end
  class CastError < Error; end

  # Raised by operations the generator refused to emit. The message names the
  # construct it could not support, so a wrong client is never silently built.
  class Unsupported < Error; end

  class HTTPError < Error
    attr_reader :status, :headers, :body, :parsed

    def initialize(status:, headers:, body:, parsed: nil)
      @status = status
      @headers = headers
      @body = body
      @parsed = parsed
      super("HTTP #{status}#{": #{parsed.inspect}" if parsed}")
    end
  end

  class ClientError < HTTPError; end
  class ServerError < HTTPError; end

  # The request did not happen: connection refused, DNS failure, a timeout.
  # Every adapter raises this rather than its own library's class, because
  # otherwise the seam leaks — an application that moves a client from
  # Net::HTTP to Faraday would find its `rescue` quietly matching nothing, and
  # a call it thought it had covered taking the process down. The original is
  # on #cause for anything that does want to know.
  class ConnectionError < Error; end

  # What a transport failure looks like from the stdlib, which an adapter an
  # application wrote itself is likely to let through as-is. Net::OpenTimeout
  # and Net::ReadTimeout are Timeout::Error; Errno::ECONNREFUSED and the rest
  # of Errno are SystemCallError. socket and timeout are required above for
  # these two names, which is all the runtime itself wants from a transport.
  TRANSPORT_ERRORS = [IOError, SystemCallError, SocketError, Timeout::Error].freeze

  # The words Ruby will not read as a name. Lives here rather than with the
  # generator's other name tables because the generated method body has to
  # know too: a parameter may be named for one of these, and reading it is
  # not a matter of writing it down.
  KEYWORDS = %w[
    BEGIN END alias and begin break case class def defined do else elsif end ensure false for if in module
    next nil not or redo rescue retry return self super then true undef unless until when while yield __FILE__
    __LINE__ __ENCODING__
  ].freeze

  module_function

  def camelize(name)
    head, *rest = name.to_s.split("_")
    head + rest.map(&:capitalize).join
  end

  def snake(name)
    name.to_s
        .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
        .gsub(/([a-z\d])([A-Z])/, '\1_\2')
        .tr("- ", "__")
        .gsub(/[^a-zA-Z0-9_]/, "")
        .downcase
  end

  # `timeout:` as every adapter takes it: one number for both phases, or
  # `{ open: 2, read: 10 }` for two. They are usually two different patiences
  # — how long to wait to find out a host is not there is not how long to wait
  # for a slow answer — and a client sitting inside somebody else's request
  # has to bound the first one much more tightly than the second.
  def timeouts(timeout)
    return [timeout, timeout] unless timeout.is_a?(Hash)

    unknown = timeout.keys - %i[open read]
    raise ArgumentError, "timeout: takes open: and read:, not #{unknown.map(&:inspect).join(", ")}" if unknown.any?

    [timeout[:open], timeout[:read]]
  end

  # Coerce a decoded JSON value into a declared type.
  #
  # Types are written the way they read: Integer, String, :bool, Time,
  # [Pet] for an array, { String => Pet } for a map, :any to pass through.
  def coerce(type, value, path)
    return nil if value.nil?

    case type
    when Array  then Array(value).each_with_index.map { |v, i| coerce(type.first, v, "#{path}[#{i}]") }
    when Hash
      # A map's keys are the document's own, whatever they turn out to be, and
      # only the values have a declared type. Something that is not an object
      # cannot be read as one, and saying so here is what keeps a bare `to_h`
      # from raising a NoMethodError with none of the path in it.
      raise CastError, "#{path}: expected an object, got #{value.class}" unless value.is_a?(Hash)

      value.to_h { |k, v| [k, coerce(type.values.first, v, "#{path}.#{k}")] }
    when :any   then value
    when :bool  then !!value
    when Symbol then value
    when Proc   then coerce(type.call, value, path) # breaks reference cycles
    else
      if type.respond_to?(:cast) then type.cast(value, path)
      elsif type == String       then value.is_a?(String) ? value : value.to_s
      elsif type == Integer      then Integer(value)
      elsif type == Float        then Float(value)
      elsif type == Time         then value.is_a?(Time) ? value : Time.parse(value.to_s)
      elsif type == Date         then value.is_a?(Date) ? value : Date.parse(value.to_s)
      else raise CastError, "#{path}: don't know how to cast to #{type.inspect}"
      end
    end
  rescue ArgumentError, TypeError => e
    raise CastError, "#{path}: #{e.message} (got #{value.inspect})"
  end

  # Inverse of #coerce: a Ruby value on its way into a request body.
  def dump(value)
    case value
    when Time         then value.iso8601
    when Date         then value.iso8601
    when Array        then value.map { dump(_1) }
    when Hash         then value.to_h { |k, v| [k.to_s, dump(v)] }
    else value.respond_to?(:to_json_hash) ? value.to_json_hash : value
    end
  end

  # What a table of responses says about one status. A document keys an entry
  # by the code itself, by one of the ranges it is allowed to write in place of
  # one — "4XX" for every client error — or by `default` for whatever it did
  # not describe. The narrowest of them answers: a 404 is answered by its own
  # entry before the range's, and by the range's before the catch-all, which is
  # the order the document wrote them in for.
  def for_status(table, status)
    table[status] || table["#{status / 100}XX"] || table[:default]
  end

  # Build a value type for one schema.
  #
  #   Pet = Keiyaku.model({ id: Integer, name: String }, required: %i[name])
  #
  # Returns a Keiyaku::Model subclass, so callers get immutability, #with and
  # pattern matching. Missing optional fields arrive as nil rather than
  # raising, and unknown fields in a response are ignored so that a server
  # adding a field does not break an old client.
  #
  # The fields are a positional Hash rather than keywords because they are the
  # API's names, not ours: a DIDComm message has a property called `from`, and
  # as keywords it would have quietly taken the place of the option below it.
  #
  # `open:` is what the document's `additionalProperties` said: false for a
  # schema that named all its properties, true for one that allows any others,
  # or the type it declared for their values.
  def model(fields, required: [], from: {}, open: false)
    Class.new(Model) { __define(fields, required:, from:, open:) }
  end

  # The value type a schema becomes: frozen, compared by value, copied with
  # #with, matched with `in`. One subclass per schema, built by Keiyaku.model,
  # with a matching RBS class emitted beside the generated code.
  #
  # This was a Data subclass until `additionalProperties` needed somewhere to
  # put the properties a document permits but does not name. A Data's members
  # are the whole of its state, so an overflow could only have been one more
  # member — turning up in #members, #to_h and every pattern match, which is
  # precisely what those keys are not. Written out, the overflow is an
  # ordinary ivar and the shape a model presents stays the schema's.
  class Model
    class << self
      # The schema as the generator read it: field name => type, in the
      # document's order. `members` is the same list without the types.
      attr_reader :members, :types

      # Field name => the name it goes by on the wire.
      attr_reader :json_names

      attr_reader :required

      # What `additionalProperties` said: false, true, or a type for the
      # values. Reading it is how #cast and #[] know which they are dealing
      # with; `open?` is the question almost everything actually asks.
      attr_reader :additional

      def open? = !!@additional

      def __define(fields, required:, from:, open:)
        @types = fields.freeze
        @members = fields.keys.freeze
        @json_names = @members.to_h { |field| [field, (from[field] || Keiyaku.camelize(field)).to_s] }.freeze
        @required = required.freeze
        @additional = open

        # define_method takes a name Ruby will not parse as one, and
        # public_send reads it back; only the dot is out of reach.
        @members.each { |field| define_method(field) { @attributes[field] } }
      end

      def cast(value, path = (name || "value"))
        return value if value.is_a?(self)
        raise CastError, "#{path}: expected an object, got #{value.class}" unless value.is_a?(Hash)

        attrs = types.to_h do |field, type|
          json = json_names[field]
          raw = value.key?(json) ? value[json] : value[field.to_s]
          if raw.nil? && required.include?(field) && !value.key?(json)
            raise CastError, "#{path}: missing required field #{json.inspect}"
          end

          [field, Keiyaku.coerce(type, raw, "#{path}.#{field}")]
        end

        return new(**attrs) unless open?

        # Everything the schema did not name, under the spelling it arrived
        # with: a declared field has `from:` to translate its name and an
        # undeclared one has nothing, so camelizing it would be a guess. That
        # is also what makes the round trip lossless.
        extra = value.except(*json_names.values, *members.map(&:to_s)).to_h do |key, raw|
          [key.to_sym, additional == true ? raw : Keiyaku.coerce(additional, raw, "#{path}.#{key}")]
        end

        new(**attrs, **extra)
      end
    end

    # Lenient about what is missing, strict about what it does not know.
    # A field left out is nil, because a schema with thirty optional
    # properties is not worth thirty keywords at every call site; a field that
    # is not in the schema is a typo, and the alternative to saying so is a
    # request that quietly goes out without it. On an open model there is no
    # such thing as a keyword the schema did not mention, so it is kept.
    def initialize(**kw)
      members = self.class.members
      unknown = kw.keys - members
      if unknown.any? && !self.class.open?
        raise ArgumentError, "unknown keyword#{"s" if unknown.size > 1}: #{unknown.map(&:inspect).join(", ")}"
      end

      @attributes = members.to_h { |field| [field, kw[field]] }.freeze
      @extra = unknown.to_h { |key| [key.to_s, kw[key]] }.freeze
      freeze
    end

    # How a field is read when its name is not one Ruby will take through a
    # dot: GitHub counts thumbs-up reactions in a property called `+1`, and
    # renaming it here would be inventing a name the document never used.
    # Ordinary fields answer to it too, so nothing has to know which is which.
    #
    # On a closed model a name it does not have is a typo rather than a nil.
    # An open model was told there would be names it does not have, so the
    # same premise says the opposite there: this is where the overflow is
    # read, and a miss is nil the way it is in a Hash.
    def [](name)
      field = name.to_sym
      return @attributes[field] if @attributes.key?(field)
      return @extra[name.to_s] if self.class.open?

      raise ArgumentError, "#{self.class} has no field #{name.inspect}"
    end

    def with(**kw) = self.class.new(**@attributes, **@extra.transform_keys(&:to_sym), **kw)

    def to_h(&block) = block ? @attributes.to_h(&block) : @attributes.dup

    def deconstruct = @attributes.values

    def deconstruct_keys(keys)
      return @attributes.dup if keys.nil?

      keys.each_with_object({}) { |key, found| found[key] = @attributes[key] if @attributes.key?(key) }
    end

    # Read through the ivars rather than a reader of this class's own: a
    # property may be named anything at all, and a document with one named for
    # that reader would quietly break equality instead of merely shadowing a
    # method nothing calls.
    def ==(other)
      return false unless other.instance_of?(self.class)

      @attributes == other.instance_variable_get(:@attributes) &&
        @extra == other.instance_variable_get(:@extra)
    end

    def eql?(other)
      return false unless other.instance_of?(self.class)

      @attributes.eql?(other.instance_variable_get(:@attributes)) &&
        @extra.eql?(other.instance_variable_get(:@extra))
    end

    def hash = [self.class, @attributes, @extra].hash

    def inspect
      shown = @attributes.map { |field, value| "#{field}=#{value.inspect}" }
      # The overflow prints as the bag it is, so a key the schema never named
      # does not read as one it did — and prints only when there is something
      # in it. It has no reader of its own, so leaving it out entirely would
      # make it visible only to someone who already knew the key to ask for.
      shown << @extra.inspect unless @extra.empty?
      "#<#{self.class.name || "Keiyaku::Model"}#{" " unless shown.empty?}#{shown.join(", ")}>"
    end

    alias to_s inspect

    def to_json_hash
      named = self.class.json_names.filter_map do |field, json|
        value = @attributes[field]
        [json, Keiyaku.dump(value)] unless value.nil?
      end.to_h
      return named if @extra.empty?

      named.merge(@extra.transform_values { Keiyaku.dump(_1) })
    end

    def to_json(*args) = to_json_hash.to_json(*args)
  end

  # A union with a discriminator: into: OneOf[Dog, Cat, on: "petType"]
  class OneOf
    def self.[](*variants, on:, map: {}) = new(variants, on, map)

    def initialize(variants, discriminator, map)
      @variants = variants
      @discriminator = discriminator
      @map = map
    end

    def cast(value, path = "value")
      raise CastError, "#{path}: expected an object" unless value.is_a?(Hash)

      tag = value[@discriminator]
      variant = @map[tag] || @variants.find { |v| Keiyaku.snake(v.name.to_s.split("::").last) == Keiyaku.snake(tag.to_s) }
      raise CastError, "#{path}: no variant for #{@discriminator}=#{tag.inspect}" unless variant

      variant.cast(value, path)
    end
  end

  # Several success responses that are several types:
  #
  #   into: ByStatus[200 => PagesHealthCheck, 202 => EmptyObject]
  #
  # Not a type — nothing casts *into* one of these — but the thing an
  # operation's `into:` is when the document gave more than one answer. The
  # document says which type belongs to which status and the response carries
  # the status, so the choice is read rather than guessed. A status the
  # document did not describe is left alone, since the alternative is a
  # CastError naming a type the server never claimed to be sending.
  class ByStatus
    def self.[](types) = new(types)

    attr_reader :types

    def initialize(types)
      @types = types.to_h { |status, type| [normalise(status), type] }.freeze
    end

    def [](status) = Keiyaku.for_status(@types, status)

    private

    # A code is the number it is however it was written, and a range is the
    # string it was written as, in the case the specification writes it in.
    def normalise(status)
      return status.to_i if status.to_s.match?(/\A\d+\z/)

      status.is_a?(String) ? status.upcase : status
    end
  end

  # One file in a multipart/form-data body.
  #
  #   Keiyaku::Upload.new(File.open("kaya.png"))
  #   Keiyaku::Upload.new(bytes, filename: "kaya.png", content_type: "image/png")
  #
  # An IO passed on its own is wrapped in one of these, so the common case
  # needs no ceremony. The content type is not guessed from the extension —
  # a wrong one is worse than the honest default.
  class Upload
    attr_reader :io, :filename, :content_type

    def initialize(io, filename: nil, content_type: nil)
      @io = io
      @filename = filename || (io.respond_to?(:path) ? File.basename(io.path) : "file")
      @content_type = content_type || "application/octet-stream"
    end

    def read = @io.respond_to?(:read) ? @io.read : @io.to_s
  end

  # Serialize parameters per the OpenAPI style/explode rules. Implemented are
  # the defaults — `form` for query, `simple` for path and header — and the
  # one rendering `deepObject` has. The generator refuses anything else rather
  # than guessing, so a name reaching `deep:` here has already been checked.
  module Serialize
    module_function

    def query(params, deep: [])
      params.flat_map do |name, value|
        next deep_object(name, value) if deep.include?(name) && !value.nil?

        case value
        when nil    then []
        when Array  then value.map { |v| [name, stringify(v)] }
        when Hash   then value.map { |k, v| [k.to_s, stringify(v)] }
        else [[name, stringify(value)]]
        end
      end
    end

    # filter[status]=live&filter[since]=2026-07-27, which is the whole of what
    # `deepObject` means. The specification stops at one level — it says
    # nothing about what a key's own value may be — so a value that is itself
    # an object or an array is refused rather than sent as whatever #to_s
    # makes of it, which no server could read back.
    def deep_object(name, value)
      fields = Keiyaku.dump(value)
      raise Error, "#{name} is #{value.class}, and a deepObject parameter is an object" unless fields.is_a?(Hash)

      fields.filter_map do |key, inner|
        next if inner.nil?

        if inner.is_a?(Hash) || inner.is_a?(Array)
          raise Error, "#{name}[#{key}] is #{inner.class}; OpenAPI does not say how deepObject nests"
        end

        ["#{name}[#{key}]", stringify(inner)]
      end
    end

    # What a path parameter has to be encoded down to: RFC 3986's unreserved
    # characters are what simple expansion may leave as they are, and this
    # matches everything else.
    ESCAPED = /[^A-Za-z0-9\-._~]/

    def path(name, value, explode: false) = simple(name, value, explode:, escape: true)

    # OpenAPI's `simple` style, which is what a path or a header parameter is
    # written in unless the document said otherwise: an array is its elements
    # separated by commas, and an object is its keys and values in that same
    # flat list — or `key=value` pairs where `explode` said so, which is the
    # one part of this a value cannot be asked and the operation has to carry.
    #
    # What it exists to keep off the wire is Ruby's own #to_s: `[1, 2]` on a
    # header reaches a server as a string with brackets and a space in it, and
    # nothing on the other side reads that back as two values.
    def simple(name, value, explode: false, escape: false)
      part = ->(inner) { simple_part(name, inner, escape:) }

      case (value = Keiyaku.dump(value))
      when Array then value.map(&part).join(",")
      when Hash  then value.map { |key, inner| "#{part.(key)}#{explode ? "=" : ","}#{part.(inner)}" }.join(",")
      else part.(value)
      end
    end

    # One value inside a simple parameter. The style's row in the
    # specification stops where deepObject's does: it gives no spelling for an
    # array or an object inside one, so that is refused rather than sent as
    # whatever #to_s makes of it.
    #
    # In a path it is percent-encoded and the separators around it are not,
    # which is RFC 6570's simple expansion and the only way the two are told
    # apart: a segment is allowed to hold a comma, so the comma between two
    # elements is left as one and a comma inside an element becomes %2C. The
    # encoding is down to the unreserved characters — a space is %20 and not
    # the `+` that means a space only in a query — and it is by byte, so a
    # name outside ASCII survives the trip. A header is not a URL and is not
    # encoded at all.
    def simple_part(name, value, escape: false)
      if value.is_a?(Array) || value.is_a?(Hash)
        raise Error, "#{name} contains #{value.class}; OpenAPI does not say how a simple parameter nests"
      end

      part = stringify(value)
      escape ? part.gsub(ESCAPED) { |char| char.each_byte.map { format("%%%02X", _1) }.join } : part
    end

    # Build a multipart/form-data body. An array property becomes one part per
    # element, which is what the default `form` encoding means for an array.
    def multipart(fields, boundary)
      parts = fields.flat_map do |name, value|
        (value.is_a?(Array) ? value : [value]).map { part(name, _1, boundary) }
      end
      parts.join.b << "--#{boundary}--\r\n".b
    end

    def part(name, value, boundary)
      value = Upload.new(value) if value.respond_to?(:read) && !value.is_a?(Upload)
      disposition = %(Content-Disposition: form-data; name="#{name}")

      headers, payload =
        case value
        when Upload
          [%(#{disposition}; filename="#{value.filename}"\r\nContent-Type: #{value.content_type}\r\n), value.read]
        when Hash, Array
          # What OpenAPI's encoding rules default to for a non-primitive part.
          ["#{disposition}\r\nContent-Type: application/json\r\n", JSON.generate(value)]
        else
          ["#{disposition}\r\n", stringify(value)]
        end

      "--#{boundary}\r\n#{headers}\r\n".b << payload.to_s.b << "\r\n".b
    end

    def stringify(value)
      case value
      when Time then value.iso8601
      when Date then value.iso8601
      else value.to_s
      end
    end
  end

  # Transport. An adapter is any object with
  #
  #   call(verb, uri, headers, body) -> [status, headers, body]
  #
  # where verb is a lower-case Symbol, headers going out is a String => String
  # Hash, and body is a String or nil. Response header names may come back in
  # whatever case the underlying library uses; the client lower-cases them
  # before looking anything up, so an adapter cannot get that wrong.
  #
  # This is the only part of the runtime a host application might want to
  # replace, which is why it is one method with no state.
  #
  # Every adapter is a file of its own, this one included: the runtime says
  # what the seam is and holds none of it. The stdlib one is autoloaded rather
  # than opted into like faraday's and http.rb's, because it is the default a
  # client builds when it was given no adapter — an application that named its
  # own should not have to load net/http to find that out.
  autoload :NetHTTPAdapter, File.expand_path("adapters/net_http", __dir__)

  # Base class for generated clients. The generated subclass contains one
  # declaration per operation and nothing else.
  class Client
    class << self
      attr_reader :operations

      def inherited(subclass)
        super
        subclass.instance_variable_set(:@operations, operations&.dup || {})
        subclass.instance_variable_set(:@server, @server)
        subclass.instance_variable_set(:@security, @security)
        subclass.instance_variable_set(:@default_security, @default_security)
      end

      def server(url = nil) = url ? @server = url : @server

      # The document's security schemes, by the name it gave them, plus the
      # requirement that holds for an operation which does not state its own.
      #
      #   security({ api_key: { header: "api_key" }, petstore_auth: :bearer },
      #            default: :api_key)
      #
      # A scheme is `:bearer`, `:basic`, or one of `{ header: }`, `{ query: }`,
      # `{ cookie: }` naming where an API key goes. Credentials are then given
      # by scheme name, because a document that declares two has no single
      # "the" credential and picking one for the caller is how a client ends
      # up sending the wrong header to every operation it has.
      def security(schemes = nil, default: nil)
        return @security || {} if schemes.nil?

        @security = schemes.to_h { |name, scheme| [name.to_sym, scheme] }
        @default_security = requirement(default)
      end

      def default_security = @default_security || []

      # A security requirement is a list of alternatives, each of which is a
      # set of schemes that all have to be satisfied: OpenAPI's OR of ANDs.
      # `false` and `[]` are the operation that takes no credentials at all,
      # which is not the same as one that does not say.
      def requirement(declared)
        case declared
        when nil, false then []
        when Symbol then [[declared]]
        else declared.map { |alternative| Array(alternative).map(&:to_sym) }
        end
      end

      %i[get post put patch delete head options].each do |verb|
        define_method(verb) do |name, template, **options|
          operation(verb, name, template, **options)
        end
      end

      # Declare one operation, and define a real method for it.
      #
      # `required:` names the query and header parameters a caller has to
      # pass, by the name the document gave them — which for a header is the
      # name on the wire rather than the Ruby one it arrives under:
      #   get :find, "/pets", query: %i[status limit], required: %i[status]
      #
      # `deep_object:` names the query parameters the document gave
      # `style: deepObject`, which go out spelled a key at a time:
      #   get :list, "/widgets", query: %i[filter], deep_object: %w[filter]
      #
      # `explode:` names the path and header parameters the document wrote
      # `explode` on, which is the one thing that cannot be read off the value
      # itself: an object goes out as `role=admin,name=alex` where it was said
      # and as `role,admin,name,alex` where it was not.
      def operation(verb, name, template, query: [], deep_object: [], header: {}, explode: [], required: [],
                    body: nil, form: nil, multipart: nil, content_type: nil, body_required: false, into: nil,
                    errors: {}, security: :inherit)
        path_params = template.scan(/\{(\w+)\}/).flatten
        # A name in `required:` that belongs to no parameter of this operation
        # would quietly leave a required one optional, which is a 400 at the
        # first call rather than an ArgumentError at the first load.
        needed = required.map(&:to_s)
        declared = query.map(&:to_s) + header.keys.map(&:to_s)
        unless (unknown = required.reject { declared.include?(_1.to_s) }).empty?
          raise ArgumentError, "#{self}##{name}: required: names #{unknown.map(&:inspect).join(", ")}, " \
                               "which is not a query or header parameter of this operation"
        end

        query_params = query.map { [_1.to_s, needed.include?(_1.to_s)] }
        header_params = header.map { |json, ruby| [json.to_s, ruby.to_s, needed.include?(json.to_s)] }

        operations[name] = {
          verb:, template:, body:, form:, multipart:, content_type:, into:, errors:,
          # nil is the operation that said nothing and takes the document's
          # requirement; every other spelling is a requirement of its own.
          security: (security == :inherit ? nil : requirement(security)),
          path: path_params, query: query_params, header: header_params,
          deep_object: deep_object.map(&:to_s), explode: explode.map(&:to_s)
        }

        positional = path_params.map { Keiyaku.snake(_1) }
        # A body is optional unless it was required, which is the default the
        # specification sets and this says nothing more than. The method can
        # then be called without one, and UNSET is how the caller says nothing
        # rather than says nothing in particular: `nil` is a body, and goes out
        # as `null`.
        positional << (body_required ? "body" : "body = Keiyaku::UNSET") if body || form || multipart
        keywords = query_params.map { |param, req| "#{Keiyaku.snake(param)}:#{" Keiyaku::UNSET" unless req}" } +
                   header_params.map { |_, ruby, req| "#{ruby}:#{" Keiyaku::UNSET" unless req}" }

        # `def find(until: nil)` is a method Ruby will define, but `until` in
        # its body starts a loop rather than naming the argument — a keyword
        # argument's label only becomes a readable local by that route. The
        # binding has it under the document's name either way, which is why
        # such a parameter is generated rather than refused.
        read = ->(ruby) { KEYWORDS.include?(ruby) ? "binding.local_variable_get(:#{ruby})" : ruby }

        arguments = <<~RUBY.chomp
          path: {#{path_params.map { "#{_1.inspect} => #{Keiyaku.snake(_1)}" }.join(", ")}},
            query: {#{query_params.map { |p, _| "#{p.inspect} => #{read.(Keiyaku.snake(p))}" }.join(", ")}},
            header: {#{header_params.map { |json, ruby, _| "#{json.inspect} => #{read.(ruby)}" }.join(", ")}},
            body: #{body || form || multipart ? "body" : "nil"}
        RUBY

        # Built as source so the method has a real signature: correct arity,
        # correct keyword names, correct errors, and introspectable by tooling.
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          def #{name}(#{(positional + keywords).join(", ")})
            __invoke(:#{name}, #{arguments})
          end
        RUBY
      end

      # An operation the generator could not build correctly. Declaring it keeps
      # the omission visible instead of leaving a silent hole in the client.
      def unsupported(name, reason)
        operations[name] = { unsupported: reason }
        define_method(name) do |*, **|
          raise Unsupported, "#{self.class}##{name} was not generated: #{reason}"
        end
      end
    end

    attr_reader :base_url

    def initialize(base_url: nil, auth: nil, adapter: nil, timeout: 15, retries: 0, logger: nil)
      # A document with no `servers` is ordinary for anything not published on
      # the open internet — a sidecar, something behind a mesh — so the address
      # has to come from the application. Saying so here beats an ArgumentError
      # out of URI at the first call.
      url = base_url || self.class.server
      raise Error, "#{self.class} has no server declared; build it with base_url:" if url.to_s.empty?

      @base_url = url.chomp("/")
      @credentials = __credentials(auth)
      @adapter = adapter || NetHTTPAdapter.new(timeout:)
      @retries = retries
      @logger = logger
    end

    private

    # Credentials, by the name the document gave the scheme. A single value is
    # allowed where there is only one scheme to mean, since naming it would
    # then be ceremony; with two it is refused rather than assigned to
    # whichever came first, which is the mistake that sends an API key to an
    # endpoint that documents OAuth.
    def __credentials(auth)
      schemes = self.class.security
      return {} if auth.nil?

      if auth.is_a?(Hash)
        credentials = auth.to_h { |name, value| [name.to_sym, value] }
        unknown = credentials.keys - schemes.keys
        unless unknown.empty?
          raise ArgumentError, "#{self.class}: no security scheme named #{unknown.map(&:inspect).join(", ")}; " \
                               "#{schemes.empty? ? "the document declares none" : "it declares #{schemes.keys.map(&:inspect).join(", ")}"}"
        end

        credentials
      elsif schemes.size == 1
        { schemes.keys.first => auth }
      elsif schemes.empty?
        raise ArgumentError, "#{self.class} declares no security schemes; send credentials as a header parameter"
      else
        raise ArgumentError, "#{self.class} declares #{schemes.keys.map(&:inspect).join(", ")}; " \
                             "say which the credential is, as auth: { #{schemes.keys.first}: ... }"
      end
    end

    # The whole of one call: the request this operation describes, and the
    # response read back under the type the document gave it.
    def __invoke(name, path:, query:, header:, body:)
      op = self.class.operations.fetch(name)

      headers = { "Accept" => "application/json" }
      credentials = []
      __authenticate(name, op, headers, credentials)

      uri = URI.parse(@base_url + __path(op, path))
      pairs = Serialize.query(query.reject { |_, v| UNSET.equal?(v) }, deep: op[:deep_object]) + credentials
      uri.query = URI.encode_www_form(pairs) unless pairs.empty?

      # After the credentials, so an explicit parameter of the same name wins.
      header.each do |param, value|
        next if UNSET.equal?(value)

        headers[param] = Serialize.simple(param, value, explode: op[:explode].include?(param))
      end

      payload =
        if UNSET.equal?(body)
          # An optional body left out is no body at all: no bytes, and no
          # Content-Type claiming there are some.
          nil
        elsif op[:multipart]
          boundary = "keiyaku-#{SecureRandom.hex(16)}"
          headers["Content-Type"] = "multipart/form-data; boundary=#{boundary}"
          Serialize.multipart(Keiyaku.dump(body), boundary)
        elsif op[:form]
          headers["Content-Type"] = "application/x-www-form-urlencoded"
          URI.encode_www_form(Keiyaku.dump(body))
        elsif %i[binary text].include?(op[:body])
          headers["Content-Type"] = op[:content_type]
          body.respond_to?(:read) ? body.read : body
        elsif op[:body]
          # The document's own media type where it named one: a `+json` vendor
          # type is these bytes under the name its server documents.
          headers["Content-Type"] = op[:content_type] || "application/json"
          JSON.generate(Keiyaku.dump(body))
        end

      status, response_headers, raw = __send_with_retries(op[:verb], uri, headers, payload)
      parsed = __parse(raw, response_headers)

      unless (200..299).cover?(status)
        error_type = Keiyaku.for_status(op[:errors], status)
        parsed = __cast_error(error_type, parsed) if error_type
        klass = status >= 500 ? ServerError : ClientError
        raise klass.new(status:, headers: response_headers, body: raw, parsed:)
      end

      into = op[:into]
      into = into[status] if into.is_a?(ByStatus)
      into ? Keiyaku.coerce(into, parsed, name.to_s) : parsed
    end

    # The template with each of its parameters written into it, in the same
    # `simple` style a header is written in.
    def __path(op, path)
      op[:template].gsub(/\{(\w+)\}/) { Serialize.path($1, path.fetch($1), explode: op[:explode].include?($1)) }
    end

    # The error body under the type the document declared for that status —
    # every type, and not only the ones that are a model: an error described
    # as a list of problems is a list of them, and one described as a map was
    # calling Hash#cast, which is a NoMethodError in place of the error the
    # server actually sent.
    #
    # A body that does not fit the type it was declared with is left as it
    # arrived. That is ordinary on this side of the split — what answers a 502
    # is usually written by a proxy that never read the document — and the
    # status is what the caller is rescuing for. Raising a CastError here
    # would take that away, along with the body it would be diagnosed from.
    def __cast_error(type, parsed)
      Keiyaku.coerce(type, parsed, "error")
    rescue CastError
      parsed
    end

    def __send_with_retries(verb, uri, headers, payload)
      attempt = 0

      loop do
        begin
          @logger&.debug { "#{verb.to_s.upcase} #{uri}" }
          status, response_headers, raw = @adapter.call(verb, uri, headers, payload)
        rescue ConnectionError, *TRANSPORT_ERRORS => e
          # Nothing came back at all. The shipped adapters have already said
          # so in the one class an application can rescue; one written around
          # another library may not have, and the caller should not have to
          # know which library refused the connection in order to catch it.
          error = e.is_a?(ConnectionError) ? e : ConnectionError.new("#{verb.to_s.upcase} #{uri}: #{e.message}")
          raise error unless attempt < @retries

          attempt += 1
          sleep(__backoff(attempt))
          next
        end

        response_headers = __normalize(response_headers)
        return [status, response_headers, raw] unless (status == 429 || status >= 500) && attempt < @retries

        attempt += 1
        # Retry-After is an instruction; obey it. The fallback is ours.
        sleep(__retry_after(response_headers["retry-after"]) || __backoff(attempt))
      end
    end

    # RFC 7231 §7.1.3 writes Retry-After two ways: the seconds to wait, or the
    # date at which the wait is over. Both are ordinary, and reading only the
    # first turns the second into an ArgumentError raised from the middle of a
    # retry — out of a call the header was asking to have made again.
    #
    # A header in neither form is no instruction at all and leaves the wait to
    # the backoff. A date already past is one, and says to go now.
    def __retry_after(value)
      return if value.nil?

      seconds = Float(value, exception: false) || __seconds_until(value)
      seconds && [seconds, 0.0].max
    end

    def __seconds_until(date)
      Time.httpdate(date) - Time.now
    rescue ArgumentError
      nil
    end

    # Half the wait fixed, half random, so a fleet that trips the same rate
    # limit at the same moment does not come back at the same moment either.
    # This is deliberately the least it can be: a host application that wants
    # a real retry policy should put the client on an adapter that has one.
    def __backoff(attempt) = 2**attempt * (0.5 + (rand * 0.5))

    # Every header lookup below is lower-case, which held only by accident of
    # Net::HTTP downcasing its own. Doing it here means an adapter that hands
    # back "Content-Type" cannot silently turn every JSON response into a
    # String. Repeated headers keep the first value.
    def __normalize(headers)
      headers.to_h { |name, value| [name.to_s.downcase, value.is_a?(Array) ? value.first : value] }
    end

    def __parse(raw, headers)
      return nil if raw.nil? || raw.empty?
      return raw unless headers.fetch("content-type", "").include?("json")

      JSON.parse(raw)
    rescue JSON::ParserError
      raw
    end

    # Put on the request exactly what this operation says it needs, which is
    # not necessarily what the document's other operations need. Alternatives
    # are tried in the order the document wrote them, preferring one that
    # actually authenticates: `security: [{}, { api_key: [] }]` is an
    # operation that will serve anonymous callers but should still recognise
    # one who has a key.
    def __authenticate(name, op, headers, credentials)
      alternatives = op[:security] || self.class.default_security
      return if alternatives.empty?

      chosen = alternatives.reject(&:empty?).find { |schemes| schemes.all? { @credentials.key?(_1) } }
      chosen ||= [] if alternatives.any?(&:empty?)

      # A client built with no credentials at all is taken at its word: plenty
      # of servers do not enforce what their document declares, and refusing
      # to make the call would be this library deciding otherwise. One built
      # with some, but not the ones this operation names, is a mistake worth
      # more than the 401 it would come back with.
      if chosen.nil?
        return if @credentials.empty?

        raise Error, "#{self.class}##{name} requires #{alternatives.map { _1.join(" and ") }.join(" or ")}, " \
                     "and was built with #{@credentials.keys.join(", ")}"
      end

      chosen.each { __apply_credential(_1, headers, credentials) }
    end

    def __apply_credential(scheme, headers, credentials)
      case [self.class.security.fetch(scheme), @credentials.fetch(scheme)]
      in [:bearer, token] then headers["Authorization"] = "Bearer #{token}"
      in [:basic, secret]
        pair = secret.is_a?(Array) ? secret.join(":") : secret.to_s
        headers["Authorization"] = "Basic #{[pair].pack("m0")}"
      in [{ header: key }, token] then headers[key.to_s] = Serialize.stringify(token)
      in [{ query: key }, token] then credentials << [key.to_s, Serialize.stringify(token)]
      in [{ cookie: key }, token]
        headers["Cookie"] = [headers["Cookie"], "#{key}=#{Serialize.stringify(token)}"].compact.join("; ")
      else
        raise Error, "#{self.class}: #{scheme} is declared as #{self.class.security.fetch(scheme).inspect}, " \
                     "which is not a scheme this runtime knows how to send"
      end
    end
  end
end
