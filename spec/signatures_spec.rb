# frozen_string_literal: true

# The DSL builds real methods with real arity, so calling one wrong fails at
# the call site rather than somewhere inside the client.
RSpec.describe "generated method signatures" do
  it "makes path parameters positional" do
    expect(Petstore::Client.instance_method(:get_pet_by_id).parameters).to eq [%i[req pet_id]]
  end

  it "makes required query parameters required keywords" do
    expect(Petstore::Client.instance_method(:find_pets_by_status).parameters).to eq [%i[keyreq status]]
  end

  it "gives optional query parameters defaults" do
    expect(Petstore::Client.instance_method(:update_pet_with_form).parameters)
      .to eq [%i[req pet_id], %i[key name], %i[key status]]
  end

  it "raises on the wrong arity, at the call" do
    expect { petstore.get_pet_by_id }.to raise_error(ArgumentError)
  end

  # Which parameters are required is said in one place rather than marked on
  # each name, so a document is free to name one `notify!` and a `required:`
  # that names nothing is a mistake worth hearing about at the first load.
  describe "required:" do
    def declaring(...)
      Class.new(Keiyaku::Client) do
        server "https://unused.test"
        get(...)
      end
    end

    it "names query and header parameters by the name the document gave them" do
      client = declaring(:find, "/things", query: %i[q], header: { "X-Region" => :x_region },
                                           required: ["q", "X-Region"])
      expect(client.instance_method(:find).parameters).to eq [%i[keyreq q], %i[keyreq x_region]]
    end

    it "says so when it names a parameter the operation does not have" do
      expect { declaring(:find, "/things", query: %i[q], required: %i[cursor]) }
        .to raise_error(ArgumentError, /required: names :cursor/)
    end
  end
end
