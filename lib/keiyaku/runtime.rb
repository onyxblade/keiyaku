# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "time"
require "date"
require "securerandom"
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

  # Coerce a decoded JSON value into a declared type.
  #
  # Types are written the way they read: Integer, String, :bool, Time,
  # [Pet] for an array, { String => Pet } for a map, :any to pass through.
  def coerce(type, value, path)
    return nil if value.nil?

    case type
    when Array  then Array(value).each_with_index.map { |v, i| coerce(type.first, v, "#{path}[#{i}]") }
    when Hash   then value.to_h { |k, v| [k, coerce(type.values.first, v, "#{path}.#{k}")] }
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

  # Build a value type for one schema.
  #
  #   Pet = Keiyaku.model({ id: Integer, name: String }, required: %i[name])
  #
  # Returns a Data subclass, so callers get immutability, #with and pattern
  # matching for free. Missing optional fields arrive as nil rather than
  # raising, and unknown fields in a response are ignored so that a server
  # adding a field does not break an old client.
  #
  # The fields are a positional Hash rather than keywords because they are the
  # API's names, not ours: a DIDComm message has a property called `from`, and
  # as keywords it would have quietly taken the place of the option below it.
  def model(fields, required: [], from: {})
    names = fields.keys
    json_names = names.to_h { |n| [n, (from[n] || camelize(n)).to_s] }

    klass = Data.define(*names) do
      # Lenient about what is missing, strict about what it does not know.
      # A field left out is nil, because a schema with thirty optional
      # properties is not worth thirty keywords at every call site; a field
      # that is not in the schema is a typo, and the alternative to saying so
      # is a request that quietly goes out without it.
      def initialize(**kw)
        members = self.class.members
        unknown = kw.keys - members
        raise ArgumentError, "unknown keyword#{"s" if unknown.size > 1}: #{unknown.map(&:inspect).join(", ")}" if unknown.any?

        super(**members.to_h { |m| [m, kw[m]] })
      end

      # How a field is read when its name is not one Ruby will take through a
      # dot: GitHub counts thumbs-up reactions in a property called `+1`, and
      # renaming it here would be inventing a name the document never used.
      # Ordinary fields answer to it too, so nothing has to know which is
      # which. A name the model does not have is a typo rather than a nil.
      def [](name)
        field = name.to_sym
        unless self.class.members.include?(field)
          raise ArgumentError, "#{self.class} has no field #{name.inspect}"
        end

        public_send(field)
      end

      def to_json_hash
        self.class.json_names.filter_map do |name, json|
          value = public_send(name)
          [json, Keiyaku.dump(value)] unless value.nil?
        end.to_h
      end

      def to_json(*args) = to_json_hash.to_json(*args)
    end

    klass.define_singleton_method(:types)      { fields }
    klass.define_singleton_method(:json_names) { json_names }
    klass.define_singleton_method(:required)   { required }

    klass.define_singleton_method(:cast) do |value, path = (name || "value")|
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

      new(**attrs)
    end

    klass
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
      @types = types.to_h { |status, type| [status.to_i, type] }.freeze
    end

    def [](status) = @types[status]
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

  # Serialize parameters per the OpenAPI style/explode rules.
  # Only the defaults are implemented: `form` for query, `simple` for path and
  # header. The generator refuses anything else rather than guessing.
  module Serialize
    module_function

    def query(params)
      params.flat_map do |name, value|
        case value
        when nil    then []
        when Array  then value.map { |v| [name, stringify(v)] }
        when Hash   then value.map { |k, v| [k.to_s, stringify(v)] }
        else [[name, stringify(value)]]
        end
      end
    end

    def path(value)
      URI.encode_www_form_component(
        value.is_a?(Array) ? value.map { stringify(_1) }.join(",") : stringify(value)
      )
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
  class NetHTTPAdapter
    def initialize(timeout: 15) = @timeout = timeout

    def call(verb, uri, headers, body)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = http.read_timeout = @timeout

      request = Net::HTTP.const_get(verb.to_s.capitalize).new(uri)
      headers.each { |k, v| request[k] = v }
      request.body = body if body

      response = http.request(request)
      [response.code.to_i, response.to_hash.transform_values(&:first), response.body]
    end
  end

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
      # Required query/header parameters are marked with a trailing bang:
      #   get :find, "/pets", query: %i[status! limit]
      #
      # `paginate:` describes how to walk the operation. OpenAPI says nothing
      # about pagination, so nothing here is inferred — the shape is declared:
      #
      #   { by: :offset, param: "offset", size: "limit", per: 100 }
      #   { by: :page,   param: "page",   size: "limit", per: 100, from: 1 }
      #   { by: :cursor, param: "cursor", next: "next_cursor", items: "items" }
      #   { by: :link }                     # RFC 8288 Link: <...>; rel="next"
      #
      # `items:` names the field holding the page's contents when the response
      # is an envelope; without it the response is the array itself.
      def operation(verb, name, template, query: [], header: {}, body: nil, form: nil,
                    multipart: nil, content_type: nil, into: nil, errors: {},
                    security: :inherit, paginate: nil)
        path_params = template.scan(/\{(\w+)\}/).flatten
        query_params = query.map { [_1.to_s.delete_suffix("!"), _1.to_s.end_with?("!")] }
        header_params = header.map { |json, ruby| [json.to_s, ruby.to_s.delete_suffix("!"), ruby.to_s.end_with?("!")] }

        operations[name] = {
          verb:, template:, body:, form:, multipart:, content_type:, into:, errors:, paginate:,
          # nil is the operation that said nothing and takes the document's
          # requirement; every other spelling is a requirement of its own.
          security: (security == :inherit ? nil : requirement(security)),
          path: path_params, query: query_params, header: header_params
        }

        positional = path_params.map { Keiyaku.snake(_1) }
        positional << "body" if body || form || multipart
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

        return unless paginate

        # Named for what it does rather than overloading the operation: one
        # call is one request, and this one is a loop of them.
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          def #{name}_each(#{[*positional, *keywords, "&block"].join(", ")})
            pages = __paginate(:#{name}, #{arguments})
            block ? pages.each(&block) : pages
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

    def __invoke(...) = __request(...).first

    # The whole of one call. Split out from __invoke only because pagination
    # needs the response headers and the ability to follow a URL the server
    # handed back, neither of which an operation method has any use for.
    def __request(name, path:, query:, header:, body:, url: nil)
      op = self.class.operations.fetch(name)

      headers = { "Accept" => "application/json" }
      credentials = []
      __authenticate(name, op, headers, credentials)

      if url
        uri = URI.parse(url)
        # A URL the server handed back carries the query it wants; the
        # credentials are ours, and still have to be on it.
        uri.query = [uri.query, URI.encode_www_form(credentials)].compact.reject(&:empty?).join("&") if credentials.any?
      else
        uri = URI.parse(@base_url + op[:template].gsub(/\{(\w+)\}/) { Serialize.path(path.fetch($1)) })
        pairs = Serialize.query(query.reject { |_, v| UNSET.equal?(v) }) + credentials
        uri.query = URI.encode_www_form(pairs) unless pairs.empty?
      end

      # After the credentials, so an explicit parameter of the same name wins.
      header.each { |k, v| headers[k] = Serialize.stringify(v) unless UNSET.equal?(v) }

      payload =
        if op[:multipart]
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
          headers["Content-Type"] = "application/json"
          JSON.generate(Keiyaku.dump(body))
        end

      status, response_headers, raw = __send_with_retries(op[:verb], uri, headers, payload)
      parsed = __parse(raw, response_headers)

      unless (200..299).cover?(status)
        error_type = op[:errors][status] || op[:errors][:default]
        parsed = error_type.cast(parsed, "error") if error_type && parsed.is_a?(Hash)
        klass = status >= 500 ? ServerError : ClientError
        raise klass.new(status:, headers: response_headers, body: raw, parsed:)
      end

      into = op[:into]
      into = into[status] if into.is_a?(ByStatus)
      [into ? Keiyaku.coerce(into, parsed, name.to_s) : parsed, response_headers]
    end

    # Walk a paginated operation, yielding items rather than pages: the page is
    # a transport detail, and an Enumerator means `.lazy.first(20)` stops after
    # as many requests as that actually needs.
    def __paginate(name, path:, query:, header:, body:)
      rule = self.class.operations.fetch(name).fetch(:paginate)
      query = query.dup

      per = rule[:per]
      if rule[:size]
        per = query[rule[:size]] unless UNSET.equal?(query[rule[:size]])
        query[rule[:size]] = per if per
      end

      Enumerator.new do |yielder|
        # A cursor is only known after a page has come back, so the first
        # request must leave the parameter off entirely.
        cursor = rule[:from] || { page: 1, offset: 0 }.fetch(rule[:by], UNSET)
        url = nil

        loop do
          query[rule[:param]] = cursor if rule[:param]
          page, headers = __request(name, path:, query:, header:, body:, url:)
          items = Array(rule[:items] ? __field(page, rule[:items]) : page)
          items.each { yielder << _1 }

          case rule[:by]
          when :offset then cursor += per || items.size
          when :page   then cursor += 1
          when :cursor then cursor = __field(page, rule[:next])
          when :link   then url = __next_link(headers["link"])
          else raise Error, "#{name}: unknown pagination strategy #{rule[:by].inspect}"
          end

          # A short page ends the walk where the server reports a page size;
          # otherwise only an empty one does, which costs one extra request.
          break if items.empty? || (per && items.size < per)
          break if rule[:by] == :cursor && (cursor.nil? || cursor.to_s.empty?)
          break if rule[:by] == :link && url.nil?
        end
      end
    end

    # A page's contents live under a JSON name in an undecoded response and
    # under the Ruby name once a model has been cast; try both.
    def __field(page, name)
      return page[name.to_s] || page[Keiyaku.snake(name)] if page.is_a?(Hash)

      page.public_send(Keiyaku.snake(name))
    end

    def __next_link(header)
      header.to_s.split(",").each do |link|
        url, *params = link.split(";").map(&:strip)
        return url[/\A<(.*)>\z/, 1] if params.any? { _1.match?(/\Arel\s*=\s*"?next"?\z/) }
      end
      nil
    end

    def __send_with_retries(verb, uri, headers, payload)
      attempt = 0
      begin
        @logger&.debug { "#{verb.to_s.upcase} #{uri}" }
        status, response_headers, raw = @adapter.call(verb, uri, headers, payload)
        response_headers = __normalize(response_headers)
        if (status == 429 || status >= 500) && attempt < @retries
          attempt += 1
          # Retry-After is an instruction; obey it. The fallback is ours.
          sleep(Float(response_headers["retry-after"] || __backoff(attempt)))
          raise IOError, "retry"
        end
        [status, response_headers, raw]
      rescue IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout
        retry if $!.message == "retry"
        raise unless attempt < @retries

        attempt += 1
        sleep(__backoff(attempt))
        retry
      end
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
