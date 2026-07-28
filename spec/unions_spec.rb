# frozen_string_literal: true

RSpec.describe "a discriminated union" do
  it "is a OneOf rather than a model subclass" do
    expect(Widgets::Event).to be_a(Keiyaku::OneOf)
  end

  it "casts each variant by its discriminator" do
    expect(widgets.list_events(1)).to match [
      an_instance_of(Widgets::WidgetCreated),
      an_instance_of(Widgets::WidgetRetired)
    ]
  end

  it "casts the variants' own fields" do
    created, retired = widgets.list_events(1)
    expect(created.widget).to be_a(Widgets::Widget).and have_attributes(id: 1)
    expect(retired.reason).to eq "end of life"
  end

  # Trying each variant until one sticks would be a guess, and a wrong one is
  # silent. An unknown tag is an error naming the tag.
  it "refuses to guess at an unknown discriminator" do
    expect { widgets.list_events(3) }.to raise_error(Keiyaku::CastError, /kind="exploded"/)
  end
end
