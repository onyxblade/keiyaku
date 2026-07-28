# frozen_string_literal: true

require "faraday"
require_relative "../runtime"

module Keiyaku
  # Puts a generated client on Faraday, so it inherits the connection pooling,
  # instrumentation and retry middleware an application has already set up.
  #
  #   require "keiyaku/adapters/faraday"
  #
  #   client = Petstore::Client.new(adapter: Keiyaku::FaradayAdapter.new(conn))
  #
  # Faraday is not a dependency of this gem, and will not become one: a client
  # for one API has no business choosing an HTTP stack for the application
  # around it. Requiring this file is how you opt in.
  #
  # With faraday-retry in the connection, build the client with `retries: 0`.
  # The middleware handles Retry-After and jitter properly; the loop in the
  # runtime is only there so the stdlib path is not defenceless.
  class FaradayAdapter
    def initialize(connection = nil, timeout: nil, **options)
      if timeout
        # Faraday has its own spelling for these, and a connection that was
        # handed in already carries whatever it was built with. Accepting the
        # option and dropping it would be the worst of the three.
        raise ArgumentError, "timeout: has no effect on a connection you built; set it on that" if connection

        open, read = Keiyaku.timeouts(timeout)
        options[:request] = { open_timeout: open, timeout: read }.merge(options[:request] || {})
      end

      @connection = connection || Faraday.new(**options)
    end

    def call(verb, uri, headers, body)
      response = @connection.run_request(verb, uri, body, headers)
      [response.status, response.headers.to_h, response.body]
    rescue Faraday::ConnectionFailed, Faraday::TimeoutError, Faraday::SSLError => e
      raise ConnectionError, "#{verb.to_s.upcase} #{uri}: #{e.message}"
    end
  end
end
