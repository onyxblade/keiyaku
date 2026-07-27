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

    it "sends header parameters" do
      petstore.delete_pet(5, api_key: "override")
      expect(sent.headers["api_key"]).to eq "override"
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
end
