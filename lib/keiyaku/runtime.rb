# frozen_string_literal: true

require "net/http"
require "json"
require "uri"
require "time"
require "date"
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
  #   Pet = Keiyaku.model(id: Integer, name: String, required: %i[name])
  #
  # Returns a Data subclass, so callers get immutability, #with and pattern
  # matching for free. Missing optional fields arrive as nil rather than
  # raising, and unknown fields in a response are ignored so that a server
  # adding a field does not break an old client.
  def model(required: [], from: {}, **fields)
    names = fields.keys
    json_names = names.to_h { |n| [n, (from[n] || camelize(n)).to_s] }

    klass = Data.define(*names) do
      def initialize(**kw)
        super(**self.class.members.to_h { |m| [m, kw[m]] })
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

    def stringify(value)
      case value
      when Time then value.iso8601
      when Date then value.iso8601
      else value.to_s
      end
    end
  end

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
      end

      def server(url = nil) = url ? @server = url : @server
      def security(scheme = nil) = scheme ? @security = scheme : @security

      %i[get post put patch delete head options].each do |verb|
        define_method(verb) do |name, template, **options|
          operation(verb, name, template, **options)
        end
      end

      # Declare one operation, and define a real method for it.
      #
      # Required query/header parameters are marked with a trailing bang:
      #   get :find, "/pets", query: %i[status! limit]
      def operation(verb, name, template, query: [], header: {}, body: nil,
                    form: nil, content_type: nil, into: nil, errors: {}, security: :inherit)
        path_params = template.scan(/\{(\w+)\}/).flatten
        query_params = query.map { [_1.to_s.delete_suffix("!"), _1.to_s.end_with?("!")] }
        header_params = header.map { |json, ruby| [json.to_s, ruby.to_s.delete_suffix("!"), ruby.to_s.end_with?("!")] }

        operations[name] = {
          verb:, template:, body:, form:, content_type:, into:, errors:, security:,
          path: path_params, query: query_params, header: header_params
        }

        positional = path_params.map { Keiyaku.snake(_1) }
        positional << "body" if body || form
        keywords = query_params.map { |param, req| "#{Keiyaku.snake(param)}:#{" Keiyaku::UNSET" unless req}" } +
                   header_params.map { |_, ruby, req| "#{ruby}:#{" Keiyaku::UNSET" unless req}" }

        # Built as source so the method has a real signature: correct arity,
        # correct keyword names, correct errors, and introspectable by tooling.
        class_eval <<~RUBY, __FILE__, __LINE__ + 1
          def #{name}(#{(positional + keywords).join(", ")})
            __invoke(:#{name},
              path: {#{path_params.map { "#{_1.inspect} => #{Keiyaku.snake(_1)}" }.join(", ")}},
              query: {#{query_params.map { |p, _| "#{p.inspect} => #{Keiyaku.snake(p)}" }.join(", ")}},
              header: {#{header_params.map { |json, ruby, _| "#{json.inspect} => #{ruby}" }.join(", ")}},
              body: #{body || form ? "body" : "nil"})
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
      @base_url = (base_url || self.class.server or raise ArgumentError, "no base_url and no server in the spec").chomp("/")
      @auth = auth
      @adapter = adapter || NetHTTPAdapter.new(timeout:)
      @retries = retries
      @logger = logger
    end

    private

    def __invoke(name, path:, query:, header:, body:)
      op = self.class.operations.fetch(name)

      url = op[:template].gsub(/\{(\w+)\}/) { Serialize.path(path.fetch($1)) }
      uri = URI.parse(@base_url + url)
      pairs = Serialize.query(query.reject { |_, v| UNSET.equal?(v) })
      uri.query = URI.encode_www_form(pairs) unless pairs.empty?

      headers = { "Accept" => "application/json" }
      headers.merge!(__auth_headers) unless op[:security] == false
      # After the credentials, so an explicit parameter of the same name wins.
      header.each { |k, v| headers[k] = Serialize.stringify(v) unless UNSET.equal?(v) }

      payload =
        if op[:form]
          headers["Content-Type"] = "application/x-www-form-urlencoded"
          URI.encode_www_form(Keiyaku.dump(body))
        elsif op[:body] == :binary
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

      op[:into] ? Keiyaku.coerce(op[:into], parsed, name.to_s) : parsed
    end

    def __send_with_retries(verb, uri, headers, payload)
      attempt = 0
      begin
        @logger&.debug { "#{verb.to_s.upcase} #{uri}" }
        status, response_headers, raw = @adapter.call(verb, uri, headers, payload)
        if (status == 429 || status >= 500) && attempt < @retries
          attempt += 1
          sleep(Float(response_headers["retry-after"] || 2**attempt))
          raise IOError, "retry"
        end
        [status, response_headers, raw]
      rescue IOError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout
        retry if $!.message == "retry"
        raise unless attempt < @retries

        attempt += 1
        sleep(2**attempt)
        retry
      end
    end

    def __parse(raw, headers)
      return nil if raw.nil? || raw.empty?
      return raw unless headers.fetch("content-type", "").include?("json")

      JSON.parse(raw)
    rescue JSON::ParserError
      raw
    end

    def __auth_headers
      case [self.class.security, @auth]
      in [_, nil] then {}
      in [:bearer, token] then { "Authorization" => "Bearer #{token}" }
      in [:basic, [user, pass]] then { "Authorization" => "Basic #{["#{user}:#{pass}"].pack("m0")}" }
      in [{ header: name }, token] then { name.to_s => token }
      in [{ query: _ }, _] then {}
      else {}
      end
    end
  end
end
