# frozen_string_literal: true

RSpec.describe "failure" do
  it "maps 4xx to an exception" do
    expect { petstore.get_pet_by_id(999) }.to raise_error(Keiyaku::ClientError) do |error|
      expect(error.status).to eq 404
      # This document declares no schema for 404, so the body stays undecoded.
      expect(error.parsed["message"]).to eq "Pet not found"
    end
  end

  it "casts a body the document declares for that status" do
    expect { widgets.create_widget(Widgets::Widget.new(id: 1, created_at: Time.now)) }
      .to raise_error(Keiyaku::ClientError) do |error|
        expect(error.parsed).to be_a(Widgets::Problem)
        expect(error.parsed.detail).to eq "that id is taken"
        # anyOf with no discriminator is typed :any, so it arrives undecoded.
        expect(error.parsed.source).to eq "id"
      end
  end

  # A document is entitled to describe its client errors by range rather than
  # one code at a time, and "4XX" is then the entry a 422 is answered by.
  it "casts an error body the document described as a range" do
    expect { widgets.add_note(2, locale: "en") }.to raise_error(Keiyaku::ClientError) do |error|
      expect(error.status).to eq 422
      expect(error.parsed).to be_a(Widgets::Problem)
      expect(error.parsed.detail).to eq "that locale is not supported"
    end
  end

  # Three ways a document can name the same response, and the narrowest of them
  # is the one it meant: writing both a 404 and a 4XX is saying that 404 is not
  # like the others.
  describe "a status a document described more than one way" do
    let(:table) { { 404 => :code, "4XX" => :range, :default => :catch_all } }

    it "answers with the code's own entry" do
      expect(Keiyaku.for_status(table, 404)).to eq :code
    end

    it "answers with the range where the code has no entry" do
      expect(Keiyaku.for_status(table, 422)).to eq :range
    end

    it "answers with the catch-all where neither covers it" do
      expect(Keiyaku.for_status(table, 503)).to eq :catch_all
    end
  end

  it "casts a default error body, and calls 5xx a ServerError" do
    expect { widgets.get_widget(2) }.to raise_error(Keiyaku::ServerError) do |error|
      expect(error.parsed).to be_a(Widgets::Problem)
      expect(error.parsed.trace_id).to eq "t-1"
    end
  end

  # A document with no `servers` — ordinary for a sidecar, or anything behind a
  # mesh — leaves the client without an address, which then has to come from
  # the application. Saying so beats an ArgumentError out of URI at the first
  # call.
  it "will not build a client that has no address at all" do
    expect { Class.new(Keiyaku::Client).new }
      .to raise_error(Keiyaku::Error, /has no server declared; build it with base_url:/)
  end

  # An operation the generator refused to translate is still defined, so the
  # failure is a named one at the call rather than a NoMethodError.
  it "raises Unsupported for an operation it refused to build" do
    expect { widgets.list_widgets }.to raise_error(Keiyaku::Unsupported, /deepObject/)
  end

  # An application rescues what it was told to rescue. If that is whichever
  # class the HTTP library underneath happens to raise, then moving the client
  # onto another one leaves the rescue matching nothing and a refused
  # connection taking the process down.
  describe "a request that never happened" do
    # A port nothing is listening on, so the failure is immediate. A black
    # hole address would make the example wait for a real timeout.
    def unreachable(**options)
      Petstore::Client.new(base_url: "http://127.0.0.1:1/api/v3", **options)
    end

    it "is a ConnectionError rather than the transport's own class" do
      expect { unreachable.get_pet_by_id(5) }.to raise_error(Keiyaku::ConnectionError, /GET/)
    end

    it "keeps the original on #cause, for anything that does want to know" do
      expect { unreachable.get_pet_by_id(5) }
        .to raise_error(Keiyaku::ConnectionError) { expect(_1.cause).to be_a(SystemCallError) }
    end

    # An adapter an application wrote itself is likely to let its library's
    # exceptions straight through. The promise holds either way.
    it "is one even from an adapter that raises its own" do
      leaky = Class.new do
        def call(*) = raise(Errno::ECONNRESET)
      end.new

      expect { unreachable(adapter: leaky).get_pet_by_id(5) }.to raise_error(Keiyaku::ConnectionError)
    end

    it "is retried as many times as the client was built for" do
      calls = 0
      flaky = Class.new do
        define_method(:call) do |*|
          calls += 1
          raise Errno::ECONNREFUSED
        end
      end.new

      expect { unreachable(adapter: flaky, retries: 2).get_pet_by_id(5) }.to raise_error(Keiyaku::ConnectionError)
      expect(calls).to eq 3
    end
  end
end
