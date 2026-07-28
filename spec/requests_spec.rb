# frozen_string_literal: true

RSpec.describe "building a request" do
  describe "a JSON body" do
    before do
      petstore.add_pet(Petstore::Pet.new(name: "Nori", photo_urls: ["https://example.test/n.jpg"],
                                         status: "pending"))
    end

    let(:request) { sent }

    it "serializes back to camelCase" do
      expect(JSON.parse(request.body)).to include("photoUrls")
    end

    it "omits fields left nil" do
      expect(JSON.parse(request.body)).not_to include("id")
    end

    it "sets Content-Type" do
      expect(request.content_type).to eq "application/json"
    end

    # POST /pet documents petstore_auth and nothing else, so this is the one
    # credential it may carry. Sending the API key as well — which is what
    # picking a scheme per document rather than per operation amounts to —
    # would put a credential on the wire that the endpoint never asked for.
    it "sends the credential the operation documents" do
      expect(request.headers["authorization"]).to eq "Bearer t0ken"
    end

    it "sends no credential the operation does not document" do
      expect(request.headers).not_to include("api_key")
    end
  end

  describe "credentials" do
    # GET /store/inventory takes the API key; GET /pet/{petId} takes either,
    # and the document lists the key first.
    it "sends the scheme the operation asks for" do
      petstore.get_inventory
      expect(sent.headers["api_key"]).to eq "secret-key"
    end

    it "takes the first alternative it can satisfy" do
      petstore.get_pet_by_id(5)
      request = sent
      expect(request.headers["api_key"]).to eq "secret-key"
      expect(request.headers).not_to include("authorization")
    end

    # The user operations document no security at all.
    it "sends none where the operation requires none" do
      petstore.login_user(username: "kaya", password: "x")
      expect(sent.headers.keys).not_to include("api_key", "authorization")
    end

    it "refuses a credential named for a scheme the document does not declare" do
      expect { Petstore::Client.new(base_url: "http://unused.test", auth: { api_ky: "typo" }) }
        .to raise_error(ArgumentError, /no security scheme named :api_ky/)
    end

    # With two schemes there is no "the" credential, and assigning one to
    # whichever scheme came first is how the wrong header gets sent.
    it "refuses a bare credential where the document declares more than one scheme" do
      expect { Petstore::Client.new(base_url: "http://unused.test", auth: "secret-key") }
        .to raise_error(ArgumentError, /say which the credential is/)
    end

    it "says which credential is missing rather than sending the request without it" do
      client = Petstore::Client.new(base_url: "http://unused.test", auth: { api_key: "secret-key" })
      expect { client.add_pet(Petstore::Pet.new(name: "Nori", photo_urls: [])) }
        .to raise_error(Keiyaku::Error, /requires petstore_auth/)
    end
  end

  describe "parameters" do
    it "serializes query parameters" do
      petstore.find_pets_by_status(status: "available")
      expect(sent.query).to eq({ "status" => "available" })
    end

    it "explodes array query parameters, form style being the default" do
      petstore.find_pets_by_tags(tags: %w[good soft])
      expect(sent.target).to end_with "?tags=good&tags=soft"
    end

    # The one thing `deepObject` means. The parameter has a type of its own,
    # so the keys that go out are the document's names for them rather than
    # whatever the caller happened to write.
    it "spells a deepObject parameter out a key at a time" do
      widgets.search_widgets(q: "kaya", filter: Widgets::SearchWidgetsFilter.new(status: "live"))
      expect(sent.query).to include("filter[status]" => "live")
    end

    it "takes a plain Hash for one, and leaves out what is not set" do
      widgets.search_widgets(q: "kaya", filter: { "since" => Time.utc(2026, 7, 26), "status" => nil })
      expect(sent.query).to eq({ "q" => "kaya", "filter[since]" => "2026-07-26T00:00:00Z" })
    end

    # OpenAPI's table stops at one level, so there is no spelling for a key
    # whose own value is an object. Sending `filter[at]={"gte"=>1}` would be
    # the runtime inventing one.
    it "refuses to nest one rather than sending what #to_s makes of it" do
      expect { widgets.search_widgets(q: "kaya", filter: { "at" => { "gte" => 1 } }) }
        .to raise_error(Keiyaku::Error, /does not say how deepObject nests/)
    end

    it "sends header parameters" do
      petstore.delete_pet(5, api_key: "override")
      expect(sent.headers["api_key"]).to eq "override"
    end

    # A header is written in `simple` style, where a list is its elements
    # separated by commas. Ruby's #to_s would put brackets and a space on the
    # wire instead, which no server reads back as two values.
    it "sends a list header the way the style spells one" do
      widgets.replace_labels(1, { "env" => "prod" }, x_tags: %w[fragile heavy])
      expect(sent.headers["x-tags"]).to eq "fragile,heavy"
    end

    # The one thing about an object that cannot be read off the value: the
    # same Hash is `role=admin` where the document wrote `explode` and
    # `role,admin` where it did not, so the operation has to carry which.
    it "sends an object header the way the document said to explode it" do
      widgets.replace_labels(1, { "env" => "prod" }, x_context: { "team" => "core", "region" => "eu" })
      expect(sent.headers["x-context"]).to eq "team=core,region=eu"
    end

    it "leaves a header parameter out when it is not given" do
      widgets.replace_labels(1, { "env" => "prod" })
      expect(sent.headers).not_to include("x-tags", "x-context")
    end

    # A path parameter is written in that same style, and no document here
    # types one as anything but a scalar. The separators are literal: a path
    # segment is allowed to hold a comma, and RFC 6570 encodes what is inside
    # the separators rather than the separators themselves.
    it "sends a path parameter that is not a scalar in the simple style" do
      targets = []
      recorder = Class.new do
        define_method(:call) do |_verb, uri, *|
          targets << uri.path.split("/").last
          [200, {}, nil]
        end
      end.new

      client = Class.new(Keiyaku::Client) do
        server "https://example.test"
        get :go, "/things/{key}"
      end.new(adapter: recorder)

      client.go([3, 4])
      client.go({ "role" => "admin", "name" => "alex" })
      expect(targets).to eq ["3,4", "role,admin,name,alex"]
    end

    # Down to RFC 3986's unreserved characters, which is what tells the two
    # commas apart: the one between two elements is the style's, and the one
    # inside an element is the caller's and cannot be left to be read as a
    # separator. A space is `%20` — `+` means a space in a query and a plus
    # sign in a path — and a slash is encoded rather than left to open a
    # segment the template never had.
    it "percent-encodes what goes inside a path parameter, and not the separators" do
      targets = []
      recorder = Class.new do
        define_method(:call) do |_verb, uri, *|
          targets << uri.path.split("/").last
          [200, {}, nil]
        end
      end.new

      client = Class.new(Keiyaku::Client) do
        server "https://example.test"
        get :go, "/things/{key}"
      end.new(adapter: recorder)

      client.go("a b/c")
      client.go(["a,b", "c"])
      client.go("café")
      expect(targets).to eq ["a%20b%2Fc", "a%2Cb,c", "caf%C3%A9"]
    end

    # `def import(until: nil)` is a method Ruby will define, and `until` in
    # its body is the start of a loop rather than the argument. Renaming it
    # would send a parameter the document never described.
    it "sends one named after a Ruby keyword under the document's name" do
      widgets.import_widgets("id\n1\n", until: Time.utc(2026, 7, 26))
      expect(sent.query).to eq({ "until" => "2026-07-26T00:00:00Z" })
    end

    it "leaves it out when it is not given" do
      widgets.import_widgets("id\n1\n")
      expect(sent.query).to be_empty
    end
  end

  it "sends bearer credentials" do
    widgets.get_widget(1)
    expect(sent.headers["authorization"]).to eq "Bearer t0ken"
  end

  describe "a binary body" do
    let!(:response) { petstore.upload_file(5, "\x89PNG\r\n".b, additional_metadata: "paw") }
    let(:request) { sent }

    it "sends the bytes untouched" do
      expect(request.body.b).to eq "\x89PNG\r\n".b
    end

    it "types it as octet-stream" do
      expect(request.content_type).to eq "application/octet-stream"
    end

    it "still sends the query parameters" do
      expect(request.query).to eq({ "additionalMetadata" => "paw" })
    end

    it "decodes the response" do
      expect(response).to be_a(Petstore::ApiResponse)
    end
  end

  # `+json` is a media type saying its bytes are JSON under a name of the
  # server's own. A server that documents one is entitled to refuse the same
  # bytes labelled application/json, so the label is the document's.
  describe "a body under a vendor media type" do
    let!(:note) { widgets.add_note(1, Widgets::Note.new(text: "chewed"), locale: "en") }
    let(:request) { sent }

    it "sends the type the document named" do
      expect(request.content_type).to eq "application/vnd.widgets.v2+json"
    end

    it "sends JSON under it, which is what the suffix says it is" do
      expect(JSON.parse(request.body)).to eq({ "text" => "chewed" })
    end

    it "decodes the response" do
      expect(note).to eq Widgets::Note.new(text: "chewed", locale: "en")
    end
  end

  # A request body is optional unless the document says otherwise, and this one
  # does not. Left out it has to be no body at all: `null` under a Content-Type
  # is a body, and one that says something the caller did not.
  describe "a body the document did not require" do
    before { widgets.add_note(1, locale: "en") }

    let(:request) { sent }

    it "sends no bytes" do
      expect(request.body.to_s).to be_empty
    end

    it "claims no media type for the bytes it did not send" do
      expect(request.headers).not_to include("content-type")
    end

    it "still sends the parameters" do
      expect(request.query).to eq({ "locale" => "en" })
    end
  end

  # A body the document describes as text goes out as it stands, like a binary
  # one; the media type is the only difference, and the document names it.
  describe "a text body" do
    let!(:response) { widgets.import_widgets("id,label\n1,prod\n") }
    let(:request) { sent }

    it "sends the string untouched" do
      expect(request.body).to eq "id,label\n1,prod\n"
    end

    it "types it as the media type the document listed first" do
      expect(request.content_type).to eq "text/csv"
    end

    it "decodes the response" do
      expect(response).to eq [Widgets::Widget.new(id: 1, created_at: Time.utc(2026, 7, 26, 10))]
    end
  end
end
