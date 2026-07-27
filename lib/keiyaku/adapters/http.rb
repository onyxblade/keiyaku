# frozen_string_literal: true

require "http"
require_relative "../runtime"

module Keiyaku
  # Puts a generated client on http.rb, which is faster than Net::HTTP and can
  # hold persistent connections.
  #
  #   require "keiyaku/adapters/http"
  #
  #   client = Petstore::Client.new(
  #     adapter: Keiyaku::HTTPAdapter.new(HTTP.persistent("https://petstore3.swagger.io"))
  #   )
  #
  # Like the Faraday one, this is an opt-in file rather than a dependency.
  # Named after the gem it requires, not after what it does — otherwise there
  # is no telling it apart from NetHTTPAdapter.
  class HTTPAdapter
    def initialize(client = nil, timeout: 15)
      @client = client || HTTP.timeout(timeout)
    end

    def call(verb, uri, headers, body)
      response = @client.headers(headers).request(verb, uri, body.nil? ? {} : { body: })
      [response.code, response.headers.to_h, response.body.to_s]
    end
  end
end
