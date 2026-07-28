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

      if body
        request.body = body
      elsif request.request_body_permitted?
        # No body is no body: an optional one left out means no bytes and no
        # Content-Type claiming there are some, which is the runtime's promise
        # and not this file's to give away. Net::HTTP hands a POST that was
        # given none an empty body of its own, and net/http before 0.5 labels
        # that application/x-www-form-urlencoded — a media type this client
        # never chose, on a request that carries nothing. Saying so here is
        # one method rather than a header to unpick later, and the length
        # still goes out as the zero it is, since a POST without one is what
        # some servers answer with 411.
        request.content_length = 0
        def request.request_body_permitted? = false
      end

      response = http.request(request)
      [response.code.to_i, response.to_hash.transform_values(&:first), response.body]
    rescue *TRANSPORT_ERRORS => e
      raise ConnectionError, "#{verb.to_s.upcase} #{uri}: #{e.message}"
    end
  end
end
