# frozen_string_literal: true

# The two generated clients, pointed at the test server. They hold no
# connection state, so building one per example costs nothing and keeps
# examples from leaking into each other.
module Clients
  # The Petstore declares two schemes and its operations do not agree on which
  # they want, so the credentials have to arrive under the names the document
  # gave them. A single value would have to be assigned to one of the two, and
  # whichever it was would be sent to operations documenting the other.
  def petstore(**options)
    Petstore::Client.new(base_url: TestServer.url("/api/v3"),
                         auth: { api_key: "secret-key", petstore_auth: "t0ken" }, **options)
  end

  def widgets(**options)
    Widgets::Client.new(base_url: TestServer.url("/v1"), auth: "t0ken", **options)
  end

  # The request the client just made.
  def sent = TestServer.take

  # The next `count` requests, oldest first.
  def sent_all(count) = Array.new(count) { TestServer.take }
end
