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
end
