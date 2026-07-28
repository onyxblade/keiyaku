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

  # An error the document typed as a list of problems is a list of them. Only
  # a model used to be cast, so every other type an errors table can hold —
  # a list, a map, an untyped body — either arrived undecoded or raised a
  # NoMethodError in place of the error the server had actually sent.
  it "casts an error body the document typed as a list" do
    expect { widgets.replace_labels(2, { "env" => "prod" }) }.to raise_error(Keiyaku::ClientError) do |error|
      expect(error.parsed).to match [an_instance_of(Widgets::Problem), an_instance_of(Widgets::Problem)]
      expect(error.parsed.map(&:detail)).to eq ["env is reserved", "team is unknown"]
    end
  end

  # What answers a 502 is usually written by a proxy that never read the
  # document, and the status is what the caller is rescuing for. Raising a
  # CastError here would take that away along with the body to diagnose it
  # from, so a body that does not fit its declared type arrives as it came.
  it "keeps an error body that does not fit the type the document declared" do
    expect { widgets.replace_labels(3, { "env" => "prod" }) }.to raise_error(Keiyaku::ClientError) do |error|
      expect(error.status).to eq 409
      expect(error.parsed).to eq({ "detail" => "not the list the document promised" })
    end
  end

  # The rest of what a generator puts in an errors table, which no document
  # here declares: a map of problems, and a response the document described
  # without giving it a shape.
  describe "an error type that is not a model" do
    def answering(type, payload)
      responder = Class.new do
        define_method(:call) { |*| [409, { "Content-Type" => "application/json" }, JSON.generate(payload)] }
      end.new

      client = Class.new(Keiyaku::Client) do
        server "https://example.test"
        get :go, "/go", errors: { 409 => type }
      end

      client.new(adapter: responder).go
    end

    it "casts one typed as a map" do
      expect { answering({ String => Widgets::Problem }, { "env" => { "detail" => "reserved" } }) }
        .to raise_error(Keiyaku::ClientError) { expect(_1.parsed["env"].detail).to eq "reserved" }
    end

    it "leaves one the document never gave a shape alone" do
      expect { answering(:any, { "detail" => "whatever this is" }) }
        .to raise_error(Keiyaku::ClientError) { expect(_1.parsed).to eq({ "detail" => "whatever this is" }) }
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

  # RFC 7231 writes Retry-After two ways, and reading only the seconds turns
  # the other into an ArgumentError raised from the middle of a retry — out of
  # the call the header was asking to have made again.
  describe "Retry-After" do
    def rate_limited(value)
      calls = 0
      responder = Class.new do
        define_method(:call) do |*|
          calls += 1
          [429, { "Content-Type" => "application/json", "Retry-After" => value }, "{}"]
        end
      end.new

      client = Class.new(Keiyaku::Client) do
        server "https://example.test"
        get :go, "/go"
      end

      expect { client.new(adapter: responder, retries: 1).go }.to raise_error(Keiyaku::ClientError)
      calls
    end

    it "waits the seconds a server asks for" do
      expect(rate_limited("0")).to eq 2
    end

    # A date already past says to go now, so this one also says the date was
    # read rather than fallen back on: the backoff would have been a second at
    # the very least.
    it "reads the date form too, rather than raising on it" do
      started = Time.now
      expect(rate_limited((Time.now - 5).httpdate)).to eq 2
      expect(Time.now - started).to be < 0.5
    end
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
