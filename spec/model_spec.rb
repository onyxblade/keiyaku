# frozen_string_literal: true

RSpec.describe "Keiyaku.model" do
  # The fields are the API's names, not ours. DIDComm messages have a property
  # called `from`, which as a keyword argument would have been swallowed by the
  # option of the same name — silently, since the last key of a Hash wins.
  describe "a field named like one of the options" do
    subject(:message) do
      Keiyaku.model(
        { id: String, from: String, to: [String], required: :bool },
        required: %i[id from],
        from: { id: "@id" }
      )
    end

    it "is kept" do
      expect(message.members).to eq %i[id from to required]
    end

    it "casts" do
      cast = message.cast({ "@id" => "1", "from" => "did:example:a", "required" => true })
      expect(cast.from).to eq "did:example:a"
      expect(cast.required).to be true
    end

    it "does not stop the options from working" do
      expect(message.required).to eq %i[id from]
      expect(message.json_names[:id]).to eq "@id"
    end

    it "serializes under the JSON names" do
      cast = message.cast({ "@id" => "1", "from" => "did:example:a" })
      expect(cast.to_json_hash).to eq({ "@id" => "1", "from" => "did:example:a" })
    end

    it "still catches a missing required field" do
      expect { message.cast({ "@id" => "1" }) }
        .to raise_error(Keiyaku::CastError, /missing required field "from"/)
    end
  end

  it "takes no options at all" do
    point = Keiyaku.model({ x: Integer, y: Integer })
    expect(point.new(x: 1, y: 2).to_json_hash).to eq({ "x" => 1, "y" => 2 })
  end
end
