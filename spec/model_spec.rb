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

  # Two directions with two different right answers. A response is the
  # server's, and a field it has added is not a reason to stop working; a
  # request is the caller's, and a keyword the schema never mentioned is a
  # typo that would otherwise go out as a body missing the field they set.
  describe "what it does with a name it does not know" do
    subject(:pet) { Keiyaku.model({ name: String, photo_urls: [String] }, required: %i[name]) }

    it "ignores it in a response" do
      expect(pet.cast({ "name" => "Nori", "vaccinated" => true }).name).to eq "Nori"
    end

    it "refuses it in a constructor" do
      expect { pet.new(name: "Nori", photo_urlz: ["typo"]) }
        .to raise_error(ArgumentError, /unknown keyword: :photo_urlz/)
    end

    it "still leaves a field it was not given as nil" do
      expect(pet.new(name: "Nori").photo_urls).to be_nil
    end
  end

  # `additionalProperties` is a document saying there will be properties it did
  # not name. DIDComm is the case in hand: the spec has header extensions of
  # its own, and an implementation may add more, so a model that dropped them
  # would be one that cannot forward a message it did not itself compose.
  describe "a model the document left open" do
    subject(:message) do
      Keiyaku.model({ id: String, body: { String => :any } }, required: %i[id], open: true)
    end

    let(:wire) { { "id" => "abc", "body" => { "content" => "hi" }, "please_ack" => ["receipt"] } }

    it "round-trips a property it was never told about" do
      expect(message.cast(wire).to_json_hash).to eq wire
    end

    it "reads it through the same [] that reads a field" do
      cast = message.cast(wire)
      expect(cast["please_ack"]).to eq ["receipt"]
      expect(cast["id"]).to eq "abc"
    end

    # The point of writing the model out rather than leaving it a Data: the
    # shape it presents stays the schema's, and the rest is carried quietly.
    it "keeps it out of the shape the schema described" do
      cast = message.cast(wire)
      expect(message.members).to eq %i[id body]
      expect(cast.to_h.keys).to eq %i[id body]
      expect(cast.deconstruct_keys(nil).keys).to eq %i[id body]
    end

    it "carries it through #with" do
      expect(message.cast(wire).with(id: "xyz")["please_ack"]).to eq ["receipt"]
    end

    it "takes one in a constructor rather than refusing it" do
      built = message.new(id: "abc", please_ack: ["receipt"])
      expect(built.to_json_hash).to eq({ "id" => "abc", "please_ack" => ["receipt"] })
    end

    # Two messages differing by one unnamed header are two messages.
    it "counts it in equality" do
      expect(message.cast(wire)).not_to eq message.cast(wire.except("please_ack"))
      expect(message.cast(wire)).to eq message.cast(wire)
    end

    # A closed model can say that a name it does not have is a typo. This one
    # was told there would be names it does not have, so it answers like a Hash.
    it "answers nil for a name nothing put there" do
      expect(message.cast(wire)["nope"]).to be_nil
    end

    it "prints what it is carrying, and only when it is carrying something" do
      expect(message.cast(wire).inspect).to include(%({"please_ack" => ["receipt"]}))
      expect(message.cast(wire.except("please_ack")).inspect)
        .to eq %(#<Keiyaku::Model id="abc", body={"content" => "hi"}>)
    end

    it "casts the values when the document declared a type for them" do
      counters = Keiyaku.model({ id: String }, open: Integer)
      expect(counters.cast({ "id" => "a", "hits" => "12" })["hits"]).to eq 12
    end
  end

  # The overflow is only ever the keys that are left, so a lookup cannot mean
  # two things and reading a field never has to go looking in the bag.
  it "does not put a field's own name in the overflow" do
    model = Keiyaku.model({ created_time: Float }, from: { created_time: "created_time" }, open: true)
    cast = model.cast({ "created_time" => 1.0 })
    expect(cast.created_time).to eq 1.0
    expect(cast.to_json_hash).to eq({ "created_time" => 1.0 })
  end
end
