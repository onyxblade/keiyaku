# frozen_string_literal: true

require "keiyaku/emitter"

# The generator's own behaviour, run over throwaway documents. The failure mode
# that matters is emitting plausible code that is subtly wrong, so what these
# check is that it says no.
RSpec.describe Keiyaku::Emitter do
  # Yields the emitter and the directory it wrote to, so an example can read
  # the generated source or load it.
  def generate(yaml, namespace: "Refused")
    Tempfile.create(["spec", ".yaml"]) do |file|
      file.write(yaml)
      file.flush
      emitter = described_class.new(file.path, namespace:)
      Dir.mktmpdir do |dir|
        emitter.emit(dir)
        yield emitter, dir if block_given?
      end
      emitter
    end
  end

  def spec(paths, servers: '[{ url: "https://refused.test" }]')
    <<~YAML
      openapi: 3.1.0
      info: { title: Refused, version: "1" }
      servers: #{servers}
      paths:
      #{paths.gsub(/^/, "  ").rstrip}
    YAML
  end

  # One GET /things, given the body of the operation.
  def document(operation, **)
    spec(<<~YAML, **)
      /things:
        get:
      #{operation.gsub(/^/, "    ").rstrip}
    YAML
  end

  # A response whose schema is the given one, for examples about types.
  def returning(schema)
    document(<<~YAML)
      operationId: listThings
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
      #{schema.gsub(/^/, "          ").rstrip}
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

  # Whether the emitted source parses and runs is not something reading it can
  # settle, so this loads it. The schema is the shape that used to fail: a
  # DIDComm message, whose properties collide with the model's own options.
  describe "the source it writes" do
    let(:schema) do
      document(<<~YAML)
        operationId: send
        requestBody:
          content:
            application/json:
              schema:
                type: object
                required: [id, from]
                properties:
                  id: { type: string }
                  from: { type: string }
                  to: { type: array, items: { type: string } }
                  created_time: { type: integer }
        responses: { "200": { description: ok } }
      YAML
    end

    after { Object.send(:remove_const, :Loadable) if Object.const_defined?(:Loadable) }

    it "loads, keeping a property that is named like an option" do
      generate(schema.sub("get:", "post:"), namespace: "Loadable") { |_, dir| load File.join(dir, "types.rb") }

      expect(Loadable::SendBody.members).to eq %i[id from to created_time]
      expect(Loadable::SendBody.required).to eq %i[id from]
      expect(Loadable::SendBody.json_names[:created_time]).to eq "created_time"
    end
  end

  # A fixed-length heterogeneous array is not something one element type can
  # describe, and taking the first element's would be a guess. Both spellings
  # reach here from real documents: `items` as a list is what TypeBox emits,
  # `prefixItems` is the 2020-12 form.
  %w[items prefixItems].each do |spelling|
    it "types a tuple written with #{spelling} as [:any]" do
      emitter = generate(returning(<<~YAML))
        type: array
        #{spelling}:
          - { type: string }
          - { type: integer }
      YAML

      expect(emitter.notes).to include(/a tuple, typed as \[:any\]/)
    end
  end

  describe "a union" do
    def result_type(schema)
      type = nil
      generate(returning(schema)) do |_, dir|
        type = File.read(File.join(dir, "client.rb"))[/into: (\S+?),?$/, 1]
      end
      type
    end

    # Casting by trying each variant until one sticks would be a guess, so a
    # union with nothing to dispatch on degrades to :any rather than to a coin
    # flip — but it is not allowed to do that quietly.
    it "with nothing to dispatch on is :any, and says so" do
      emitter = generate(returning("oneOf:\n  - { type: string }\n  - { type: integer }"))

      expect(emitter.notes).to include(/oneOf with no discriminator, typed as :any/)
      expect(emitter.refusals).to be_empty
    end

    # `anyOf: [X, {type: null}]` is how 3.1 says a field may be null. There is
    # one type in it, so calling it :any loses something for no reason.
    it "of a type and null is that type" do
      expect(result_type("anyOf:\n  - { type: string }\n  - { type: 'null' }")).to eq "String"
    end

    it "whose branches all agree is that type" do
      expect(result_type(<<~YAML)).to eq "String"
        anyOf:
          - { type: string, enum: [a] }
          - { type: string, enum: [b] }
      YAML
    end

    it "says nothing about the ones it collapses" do
      emitter = generate(returning("anyOf:\n  - { type: string }\n  - { type: 'null' }"))
      expect(emitter.notes).to be_empty
    end

    it "of genuinely different types is still :any" do
      expect(result_type(<<~YAML)).to eq ":any"
        anyOf:
          - { type: object, properties: { uri: { type: string } } }
          - { type: string }
      YAML
    end
  end

  # A document with no components writes every schema out again under each
  # operation, which would otherwise be a model per copy.
  describe "the same schema written out twice" do
    let(:twice) do
      body = <<~YAML
        requestBody:
          content:
            application/json:
              schema:
                type: object
                required: [id]
                properties:
                  id: { type: string }
                  labels: { type: array, items: { type: string } }
        responses: { "200": { description: ok } }
      YAML

      spec(<<~YAML)
        /things:
          post:
            operationId: createThing
        #{body.gsub(/^/, "    ").rstrip}
        /others:
          post:
            operationId: createOther
        #{body.gsub(/^/, "    ").rstrip}
      YAML
    end

    it "is emitted once" do
      generate(twice) do |_, dir|
        expect(File.read(File.join(dir, "types.rb")).scan(/Keiyaku\.model/).size).to eq 1
      end
    end

    it "is named for where it first appeared, and both operations use it" do
      generate(twice) do |_, dir|
        expect(File.read(File.join(dir, "client.rb")).scan(/body: (\w+)/).flatten)
          .to eq %w[CreateThingBody CreateThingBody]
      end
    end

    it "is not merged with a schema that differs" do
      generate(twice.sub("labels: { type: array, items: { type: string } }", "labels: { type: string }")) do |_, dir|
        expect(File.read(File.join(dir, "types.rb")).scan(/Keiyaku\.model/).size).to eq 2
      end
    end
  end

  # An operationId is optional, and a document a server generates from its own
  # routes often has none.
  describe "an operation with no operationId" do
    it "is named for its verb and path" do
      generate(spec("/didcomm/pack/encrypted:\n  post:\n    responses: { \"200\": { description: ok } }")) do |_, dir|
        expect(File.read(File.join(dir, "client.rb"))).to include(":post_didcomm_pack_encrypted,")
      end
    end

    it "keeps a path parameter out of the way of the collection" do
      generate(spec(<<~YAML)) do |_, dir|
        /things:
          get:
            responses: { "200": { description: ok } }
        /things/{id}:
          get:
            parameters: [{ name: id, in: path, required: true, schema: { type: string } }]
            responses: { "200": { description: ok } }
      YAML
        source = File.read(File.join(dir, "client.rb"))
        expect(source).to include(":get_things,").and include(":get_things_by_id,")
      end
    end

    it "says so when two operations would land on one name" do
      emitter = generate(spec(<<~YAML))
        /things:
          get:
            operationId: listThings
            responses: { "200": { description: ok } }
        /others:
          get:
            operationId: list_things
            responses: { "200": { description: ok } }
      YAML

      expect(emitter.notes).to include(/list_things names 2 operations/)
    end
  end

  # Ordinary for anything not published on the open internet: a sidecar, or
  # something reachable only inside a mesh.
  describe "a document with no servers" do
    let(:emitted) { generate(document("operationId: listThings\nresponses: { \"200\": { description: ok } }", servers: "[]")) }

    it "says the address has to come from the application" do
      expect(emitted.notes).to include(/no servers declared/)
    end

    it "leaves the client without one rather than with an empty string" do
      generate(document("operationId: listThings\nresponses: { \"200\": { description: ok } }", servers: "[]")) do |_, dir|
        expect(File.read(File.join(dir, "client.rb"))).to include("server nil")
      end
    end
  end
end
