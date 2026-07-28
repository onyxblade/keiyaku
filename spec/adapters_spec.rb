# frozen_string_literal: true

RSpec.describe "the adapter seam" do
  # An adapter returns headers however its HTTP library spells them, and some
  # return a list per name. Net::HTTP happens to downcase and flatten; nothing
  # else has to, so the runtime does it rather than trusting the adapter. Get
  # this wrong and every JSON response silently decodes as a String.
  it "does not depend on an adapter's header casing" do
    shouty = Class.new do
      def call(_verb, _uri, _headers, _body)
        [200, { "Content-Type" => ["application/json"] }, JSON.generate(TestServer::PET)]
      end
    end.new

    pet = Petstore::Client.new(base_url: "http://unused.test", adapter: shouty).get_pet_by_id(5)
    expect(pet).to be_a(Petstore::Pet).and have_attributes(name: "Kaya")
  end

  # Waiting to find out a host is not there and waiting for a slow answer are
  # two different patiences. A client that sits mid-request inside somebody
  # else's application has to bound the first tightly and can afford the
  # second, and one number for both makes that impossible to say.
  describe "timeout:" do
    it "takes one number for both phases" do
      adapter = Keiyaku::NetHTTPAdapter.new(timeout: 5)
      expect(adapter.instance_variable_get(:@open_timeout)).to eq 5
      expect(adapter.instance_variable_get(:@read_timeout)).to eq 5
    end

    it "takes them apart" do
      adapter = Keiyaku::NetHTTPAdapter.new(timeout: { open: 2, read: 10 })
      expect(adapter.instance_variable_get(:@open_timeout)).to eq 2
      expect(adapter.instance_variable_get(:@read_timeout)).to eq 10
    end

    it "says so rather than silently ignoring a key it does not know" do
      expect { Keiyaku::NetHTTPAdapter.new(timeout: { open: 2, write: 10 }) }
        .to raise_error(ArgumentError, /takes open: and read:, not :write/)
    end

    it "reaches the adapter the client builds for itself" do
      adapter = petstore(timeout: { open: 1, read: 20 }).instance_variable_get(:@adapter)
      expect(adapter.instance_variable_get(:@read_timeout)).to eq 20
    end
  end

  # The shipped adapters, over the same socket as everything else. Neither gem
  # is a dependency of keiyaku, so a missing one skips rather than fails.
  { "faraday" => :FaradayAdapter, "http" => :HTTPAdapter }.each do |gem_name, adapter_name|
    describe "the #{gem_name} adapter" do
      available =
        begin
          require "keiyaku/adapters/#{gem_name}"
          true
        rescue LoadError
          false
        end

      before { skip "#{gem_name} is not installed" unless available }

      subject(:client) { petstore(adapter: Keiyaku.const_get(adapter_name).new) }

      it "decodes a response" do
        expect(client.get_pet_by_id(5).name).to eq "Kaya"
      end

      it "sends the body and the credentials" do
        client.add_pet(Petstore::Pet.new(name: "Nori", photo_urls: []))
        request = sent
        expect(JSON.parse(request.body)["name"]).to eq "Nori"
        expect(request.headers["authorization"]).to eq "Bearer t0ken"
      end

      it "maps 4xx to an exception" do
        expect { client.get_pet_by_id(999) }.to raise_error(Keiyaku::ClientError) { expect(_1.status).to eq 404 }
      end
    end
  end
end
