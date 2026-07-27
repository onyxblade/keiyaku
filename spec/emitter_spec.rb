# frozen_string_literal: true

require "keiyaku/emitter"

# The generator's own behaviour, run over throwaway documents. The failure mode
# that matters is emitting plausible code that is subtly wrong, so what these
# check is that it says no.
RSpec.describe Keiyaku::Emitter do
  def generate(yaml)
    Tempfile.create(["spec", ".yaml"]) do |file|
      file.write(yaml)
      file.flush
      emitter = described_class.new(file.path, namespace: "Refused")
      Dir.mktmpdir { |dir| emitter.emit(dir) }
      emitter
    end
  end

  def document(operation)
    <<~YAML
      openapi: 3.1.0
      info: { title: Refused, version: "1" }
      servers: [{ url: "https://refused.test" }]
      paths:
        /things:
          get:
      #{operation.gsub(/^/, "      ").rstrip}
    YAML
  end

  describe "a pagination hint" do
    def paginated(hint)
      document(<<~YAML)
        operationId: listThings
        parameters:
          - { name: limit, in: query, schema: { type: integer } }
        x-keiyaku-paginate: #{hint}
        responses: { "200": { description: ok } }
      YAML
    end

    # The alternative to refusing is a client that pages forever.
    it "is refused when it names a parameter the operation does not have" do
      emitter = generate(paginated("{ by: offset, param: skip, size: limit }"))
      expect(emitter.refusals.first.reason).to include(%(param "skip" is not a query parameter))
    end

    it "is refused when the strategy is one the runtime does not implement" do
      emitter = generate(paginated("{ by: seek, param: limit }"))
      expect(emitter.refusals.first.reason).to include("unknown strategy")
    end

    it "is accepted when it names parameters the operation has" do
      emitter = generate(paginated("{ by: offset, param: limit, size: limit }"))
      expect(emitter.refusals).to be_empty
    end
  end

  # A fixed-length heterogeneous array is not something one element type can
  # describe, and taking the first element's would be a guess. Both spellings
  # reach here from real documents: `items` as a list is what TypeBox emits,
  # `prefixItems` is the 2020-12 form.
  {
    "items as a list" => "items:\n            - { type: string }\n            - { type: integer }",
    "prefixItems" => "prefixItems:\n            - { type: string }\n            - { type: integer }"
  }.each do |spelling, schema|
    it "types a tuple written with #{spelling} as [:any]" do
      emitter = generate(document(<<~YAML))
        operationId: listThings
        responses:
          "200":
            description: ok
            content:
              application/json:
                schema:
                  type: array
                  #{schema}
      YAML

      expect(emitter.notes).to include(/a tuple, typed as \[:any\]/)
    end
  end

  # Casting by trying each variant until one sticks would be a guess, so a
  # union with nothing to dispatch on degrades to :any rather than to a coin
  # flip — but it is not allowed to do that quietly.
  it "types an undiscriminated union as :any, and says so" do
    emitter = generate(document(<<~YAML))
      operationId: listThings
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
                oneOf:
                  - { type: string }
                  - { type: integer }
    YAML

    expect(emitter.notes).to include(/oneOf with no discriminator, typed as :any/)
    expect(emitter.refusals).to be_empty
  end
end
