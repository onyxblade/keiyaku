# frozen_string_literal: true

require "net/http"
require_relative "../runtime"

module Keiyaku
  # The stdlib adapter, which is what a client builds for itself when it was
  # given none. Nothing has to require this file: the runtime autoloads it on
  # that first default, so an application that named an adapter of its own
  # never pays for net/http.
  #
  # A connection per request, since Net::HTTP holding one is a state an
  # adapter with no state cannot keep. Where that cost matters, http.rb's
  # persistent client or a Faraday connection is the answer, which is what
  # those adapters are for.
  class NetHTTPAdapter
    def initialize(timeout: 15)
      @open_timeout, @read_timeout = Keiyaku.timeouts(timeout)
    end

    def call(verb, uri, headers, body)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = @open_timeout
      http.read_timeout = @read_timeout

      request = Net::HTTP.const_get(verb.to_s.capitalize).new(uri)
      headers.each { |k, v| request[k] = v }
      request.body = body if body

      response = http.request(request)
      [response.code.to_i, response.to_hash.transform_values(&:first), response.body]
    rescue *TRANSPORT_ERRORS => e
      raise ConnectionError, "#{verb.to_s.upcase} #{uri}: #{e.message}"
    end
  end
end
