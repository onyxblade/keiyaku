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

  it "casts a default error body, and calls 5xx a ServerError" do
    expect { widgets.get_widget(2) }.to raise_error(Keiyaku::ServerError) do |error|
      expect(error.parsed).to be_a(Widgets::Problem)
      expect(error.parsed.trace_id).to eq "t-1"
    end
  end

  # An operation the generator refused to translate is still defined, so the
  # failure is a named one at the call rather than a NoMethodError.
  it "raises Unsupported for an operation it refused to build" do
    expect { widgets.list_widgets }.to raise_error(Keiyaku::Unsupported, /deepObject/)
  end
end
