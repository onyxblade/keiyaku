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

    it "sends the security scheme's header" do
      expect(request.headers["api_key"]).to eq "secret-key"
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
