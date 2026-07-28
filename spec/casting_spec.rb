# frozen_string_literal: true

RSpec.describe "decoding a response" do
  describe "a model" do
    subject(:pet) { petstore.get_pet_by_id(5) }

    it "casts into the generated model type" do
      expect(pet).to be_a(Petstore::Pet).and be_frozen
    end

    it "maps camelCase onto snake_case" do
      expect(pet.photo_urls).to eq ["https://example.test/kaya.jpg"]
    end

    it "casts nested models" do
      expect(pet.category).to eq Petstore::Category.new(id: 1, name: "Dogs")
    end

    it "casts arrays of models" do
      expect(pet.tags).to eq [Petstore::Tag.new(id: 7, name: "good")]
    end

    it "ignores fields the document never mentioned" do
      expect(pet).not_to respond_to(:wingspan)
    end

    it "supports pattern matching, nesting included" do
      # Parenthesised because `in` binds tighter than the assignment.
      matched = (pet in { name: String, category: { name: "Dogs" } })
      expect(matched).to be true
    end

    it "copies with #with, leaving the original alone" do
      expect(pet.with(name: "Nori").name).to eq "Nori"
      expect(pet.name).to eq "Kaya"
    end
  end

  it "decodes an array response" do
    expect(petstore.find_pets_by_status(status: "available")).to match [an_instance_of(Petstore::Pet)]
  end

  it "decodes a map response" do
    expect(petstore.get_inventory).to eq({ "available" => 12, "sold" => 3 })
  end

  it "decodes a scalar response" do
    expect(petstore.login_user(username: "ada", password: "x")).to eq "session-token"
  end

  # The widgets document is deliberately unlike the Petstore: OAS 3.1, and
  # JSON fields that are already snake_case, which the camelCase convention
  # would otherwise guess wrong.
  describe "a document whose fields are already snake_case" do
    subject(:widget) { widgets.get_widget(1) }

    it "keeps the name as written" do
      expect(widget.created_at).to be_a(Time)
    end

    it "coerces date-time to Time" do
      expect(widget.created_at.utc.hour).to eq 10
    end

    it "decodes a map property" do
      expect(widget.labels).to eq({ "env" => "prod" })
    end

    it "decodes booleans" do
      expect(widget.retired).to be false
    end
  end

  # POST /widgets/import answers with the widgets, or with a job when there
  # are too many to do now. Both are the operation's answer, and the document
  # says which type belongs to which status, so nothing is guessed: the status
  # picks the type. The alternative is casting a job into the array's type and
  # handing back something empty.
  describe "an operation whose statuses are different types" do
    it "casts the one the document gave that status" do
      expect(widgets.import_widgets("id\n1\n")).to eq [Widgets::Widget.new(id: 1, created_at: Time.utc(2026, 7, 26, 10))]
    end

    it "casts the other one too" do
      expect(widgets.import_widgets("id\n1\n2\n3\n")).to eq Widgets::ImportQueued.new(job_id: "j-1")
    end

    it "is one type again where the statuses agree" do
      expect(Widgets::Client.operations[:get_widget][:into]).to eq Widgets::Widget
    end

    # A status the document did not describe is left alone: the alternative is
    # a CastError naming a type the server never claimed to be sending.
    it "passes through a status the document did not describe" do
      expect(Widgets::Client.operations[:import_widgets][:into][418]).to be_nil
    end
  end

  describe "a payload that does not fit" do
    it "names the offending field" do
      expect { Petstore::Pet.cast({ "name" => "x", "photoUrls" => [], "id" => "not-a-number" }) }
        .to raise_error(Keiyaku::CastError, /Petstore::Pet\.id/)
    end

    it "catches a missing required field" do
      expect { Petstore::Pet.cast({ "id" => 1 }) }
        .to raise_error(Keiyaku::CastError, /missing required field/)
    end
  end
end
