# frozen_string_literal: true

# The two generated clients, pointed at the test server. They hold no
# connection state, so building one per example costs nothing and keeps
# examples from leaking into each other.
module Clients
  def petstore(**options)
    Petstore::Client.new(base_url: TestServer.url("/api/v3"), auth: "secret-key", **options)
  end

  def widgets(**options)
    Widgets::Client.new(base_url: TestServer.url("/v1"), auth: "t0ken", **options)
  end

  # The request the client just made.
  def sent = TestServer.take

  # The next `count` requests, oldest first.
  def sent_all(count) = Array.new(count) { TestServer.take }
end
