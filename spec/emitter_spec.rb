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

  # A property Ruby will not take through a dot keeps the name the document
  # gave it: GitHub counts reactions in `+1` and `-1`. Renaming them would be
  # inventing names the document never used.
  describe "a property that cannot be a Ruby method name" do
    let(:reactions) do
      document(<<~YAML)
        operationId: getRollup
        responses:
          "200":
            description: ok
            content:
              application/json:
                schema:
                  type: object
                  required: ["+1", "-1", total]
                  properties:
                    "+1": { type: integer }
                    "-1": { type: integer }
                    total: { type: integer }
      YAML
    end

    after { Object.send(:remove_const, :Reacted) if Object.const_defined?(:Reacted) }

    it "keeps the document's name rather than mangling it" do
      generate(reactions, namespace: "Reacted") { |_, dir| load File.join(dir, "types.rb") }

      expect(Reacted::GetRollupResult.members).to eq [:"+1", :"-1", :total]
    end

    # snake drops the sign, so `-1` would otherwise pass as `_1` — a valid
    # identifier for a field that has nothing to do with it, sitting beside a
    # `+1` that was refused outright.
    it "does not let one of a pair through as an identifier" do
      emitter = generate(reactions)
      expect(emitter.refusals).to be_empty
      expect(emitter.notes).to be_empty
    end

    it "reads through [], casts and round-trips" do
      generate(reactions, namespace: "Reacted") { |_, dir| load File.join(dir, "types.rb") }
      rollup = Reacted::GetRollupResult.cast({ "+1" => 3, "-1" => 1, "total" => 4 })

      expect(rollup["+1"]).to eq 3
      expect(rollup["-1"]).to eq 1
      expect(rollup[:total]).to eq 4
      expect(rollup.to_json_hash).to eq({ "+1" => 3, "-1" => 1, "total" => 4 })
      expect { rollup["+2"] }.to raise_error(ArgumentError, /no field/)
    end

    # `attr_reader "+1":` is not RBS in either spelling, so the field is typed
    # where it is actually read.
    it "types the field on [] rather than on an attr_reader" do
      generate(reactions) do |_, dir|
        rbs = File.read(Dir[File.join(dir, "*.rbs")].first)
        expect(rbs).to include(%(def []: ("+1") -> Integer\n           | ("-1") -> Integer))
        expect(rbs).to include("attr_reader total: Integer")
      end
    end
  end

  # The runtime asks the class for its members and never the instance, so a
  # property of that name shadows a method nothing calls.
  it "keeps a property called members" do
    emitter = generate(document(<<~YAML))
      operationId: getPermissions
      responses:
        "200":
          description: ok
          content:
            application/json:
              schema:
                type: object
                properties:
                  members: { type: string }
    YAML

    expect(emitter.refusals).to be_empty
  end

  # A component that is not an object is not a Data subclass. Building one as
  # a model with no fields casts nothing, so the client loaded and typechecked
  # and then raised on the first response that carried the field.
  describe "a component that is not an object" do
    def component(schema)
      source = nil
      generate(<<~YAML) { |_, dir| source = File.read(File.join(dir, "types.rb")) }
        openapi: 3.1.0
        info: { title: Refused, version: "1" }
        servers: [{ url: "https://refused.test" }]
        paths:
          /thing:
            get:
              operationId: getThing
              responses:
                "200":
                  description: ok
                  content:
                    application/json:
                      schema: { $ref: "#/components/schemas/Named" }
        components:
          schemas:
            Named:
        #{schema.gsub(/^/, "      ").rstrip}
      YAML
      source[/^  Named = (.+)$/, 1]
    end

    it "is the scalar it says it is" do
      expect(component("type: string")).to eq "String"
      expect(component("{ type: integer }")).to eq "Integer"
      expect(component("{ type: boolean }")).to eq ":bool"
    end

    it "keeps an enum's type rather than becoming a model with no fields" do
      expect(component("{ type: string, enum: [A, B] }")).to eq "String"
    end

    # 3.1's other spelling for a nullable field.
    it "reads type as a list with null in it" do
      expect(component('{ type: ["string", "null"] }')).to eq "String"
    end

    # The array and the object inside it are two types and the document named
    # one, so `Named = [Named]` is what naming the element after the component
    # would produce.
    it "names the element of an array component for being the element" do
      expect(component(<<~YAML)).to eq "[NamedItem]"
        type: array
        items:
          type: object
          properties: { id: { type: string } }
      YAML
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

    # A discriminated union returned straight out of an operation is spelled
    # out in the signature rather than behind an alias, and RBS reads the `|`
    # in `-> A | B` as the start of a second overload. The examples have no
    # operation shaped like this, so `rake rbs` never had the chance to say so.
    describe "returned by an operation" do
      # Written out rather than built with `spec`, which indents everything it
      # is given under `paths:`; this one needs a `components:` beside them.
      let(:dispatching) do
        <<~YAML
          openapi: 3.1.0
          info: { title: Refused, version: "1" }
          servers: [{ url: "https://refused.test" }]
          paths:
            /thing:
              get:
                operationId: getThing
                responses:
                  "200":
                    description: ok
                    content:
                      application/json:
                        schema:
                          oneOf:
                            - { $ref: "#/components/schemas/Cat" }
                            - { $ref: "#/components/schemas/Dog" }
                          discriminator:
                            propertyName: kind
                            mapping: { cat: "#/components/schemas/Cat", dog: "#/components/schemas/Dog" }
          components:
            schemas:
              Cat: { type: object, properties: { kind: { type: string }, lives: { type: integer } } }
              Dog: { type: object, properties: { kind: { type: string }, good: { type: boolean } } }
        YAML
      end

      it "parenthesises the union in the return type" do
        generate(dispatching) do |_, dir|
          signature = File.read(Dir[File.join(dir, "*.rbs")].first)[/def get_thing: .*/]
          expect(signature).to eq "def get_thing: () -> (Cat | Dog)"
        end
      end

      it "emits RBS that parses" do
        available = begin
          require "rbs"
          true
        rescue LoadError
          false
        end
        skip "rbs is not installed" unless available

        generate(dispatching) do |_, dir|
          source = Dir[File.join(dir, "*.rbs")].first
          expect { RBS::Parser.parse_signature(RBS::Buffer.new(name: source, content: File.read(source))) }
            .not_to raise_error
        end
      end
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

    # Whichever was written second would take the method, and every call meant
    # for the other would go to a route it does not name.
    it "refuses both when two operations would land on one name" do
      emitter = generate(spec(<<~YAML)) do |_, dir|
        /things:
          get:
            operationId: listThings
            responses: { "200": { description: ok } }
        /others:
          get:
            operationId: list_things
            responses: { "200": { description: ok } }
      YAML
        expect(File.read(File.join(dir, "client.rb"))).to include("unsupported :list_things").once
      end

      expect(emitter.refusals.map(&:reason)).to contain_exactly(/2 operations map to this name/)
    end
  end

  # Which scheme an operation uses is a property of the operation. Taking the
  # first one the document declares and sending it everywhere is how a client
  # comes to put an API key on the eight endpoints that document OAuth.
  describe "security" do
    def secured(operations, root: "\nsecurity:\n  - adminKey: []")
      <<~YAML
        openapi: 3.1.0
        info: { title: Refused, version: "1" }
        servers: [{ url: "https://refused.test" }]#{root}
        components:
          securitySchemes:
            adminKey: { type: apiKey, in: header, name: X-Admin-Key }
            bearer: { type: http, scheme: bearer }
            mtls: { type: mutualTLS }
        paths:
        #{operations.gsub(/^/, "  ").rstrip}
      YAML
    end

    def client(document)
      source = nil
      generate(document) { |_, dir| source = File.read(File.join(dir, "client.rb")) }
      source
    end

    it "declares every scheme by the name the document gave it" do
      expect(client(secured("/a:\n  get:\n    responses: { \"200\": { description: ok } }")))
        .to include(%(security({ adminKey: { header: "X-Admin-Key" }, bearer: :bearer }, default: :adminKey)))
    end

    it "leaves an operation that takes the document's requirement alone" do
      expect(client(secured("/a:\n  get:\n    responses: { \"200\": { description: ok } }")))
        .to include(%(get    :get_a, "/a"\n))
    end

    it "states the one an operation overrides it with" do
      expect(client(secured(<<~YAML))).to include("security: :bearer")
        /a:
          get:
            security: [{ bearer: [] }]
            responses: { "200": { description: ok } }
      YAML
    end

    it "writes out a choice between schemes" do
      expect(client(secured(<<~YAML))).to include("security: [[:adminKey], [:bearer]]")
        /a:
          get:
            security: [{ adminKey: [] }, { bearer: [] }]
            responses: { "200": { description: ok } }
      YAML
    end

    it "writes out schemes that are required together" do
      expect(client(secured(<<~YAML))).to include("security: [[:adminKey, :bearer]]")
        /a:
          get:
            security: [{ adminKey: [], bearer: [] }]
            responses: { "200": { description: ok } }
      YAML
    end

    it "says so when an operation takes none and the document says otherwise" do
      expect(client(secured("/a:\n  get:\n    security: []\n    responses: { \"200\": { description: ok } }")))
        .to include("security: false")
    end

    # An OAuth 2 access token goes in the same header a bearer token does, so
    # there is nothing to refuse; obtaining it was never this client's job.
    it "sends an OAuth 2 token as the bearer token it is" do
      document = secured("/a:\n  get:\n    responses: { \"200\": { description: ok } }")
                 .sub("bearer: { type: http, scheme: bearer }", "bearer: { type: oauth2, flows: {} }")
      expect(client(document)).to include("bearer: :bearer")
    end

    it "refuses an operation whose only scheme has no way to be sent" do
      emitter = generate(secured(<<~YAML))
        /a:
          get:
            security: [{ mtls: [] }]
            responses: { "200": { description: ok } }
      YAML

      expect(emitter.refusals.first.reason).to include("requires mtls (mutualTLS), which the runtime has no way to send")
    end

    # Half a requirement is still enough to call the operation with.
    it "keeps the alternative it can satisfy, and says what it dropped" do
      emitter = generate(secured(<<~YAML)) do |_, dir|
        /a:
          get:
            security: [{ mtls: [] }, { bearer: [] }]
            responses: { "200": { description: ok } }
      YAML
        expect(File.read(File.join(dir, "client.rb"))).to include("security: :bearer")
      end

      expect(emitter.notes).to include(/the document also allows mtls, which is not supported/)
    end

    it "refuses an operation naming a scheme the document never declared" do
      emitter = generate(secured(<<~YAML))
        /a:
          get:
            security: [{ ghost: [] }]
            responses: { "200": { description: ok } }
      YAML

      expect(emitter.refusals.first.reason).to include(%(requires "ghost", which the document does not declare))
    end
  end

  # A name that is not a name is not visible in the document at all: it is
  # visible when Ruby reads the file, which is too late to say which schema
  # caused it.
  describe "a name Ruby will not take" do
    # One operation returning the first of the given component schemas.
    def named(schemas, returns: schemas.keys.first)
      <<~YAML
        openapi: 3.1.0
        info: { title: Refused, version: "1" }
        servers: [{ url: "https://refused.test" }]
        components:
          schemas:
        #{schemas.map { |name, schema| "    #{name}:\n#{schema.gsub(/^/, "      ").rstrip}" }.join("\n")}
        paths:
          /things:
            get:
              operationId: listThings
              responses:
                "200":
                  description: ok
                  content:
                    application/json: { schema: { $ref: "#/components/schemas/#{returns}" } }
      YAML
    end

    it "makes a constant out of one that is not one already" do
      generate(named({ "problem-details" => "type: object\nproperties: { title: { type: string } }" })) do |_, dir|
        expect(File.read(File.join(dir, "types.rb"))).to include("ProblemDetails = Keiyaku.model")
      end
    end

    # Emitting the second over the first would leave every operation typed as
    # the first casting into a model that is no longer the one it named.
    it "refuses two schemas that want one constant" do
      emitter = generate(named({ "Pet-Owner" => "type: object\nproperties: { name: { type: string } }",
                                 "PetOwner" => "type: object\nproperties: { id: { type: integer } }" }))

      expect(emitter.refusals.first.reason).to include(%(schemas "Pet-Owner" and "PetOwner" both map to PetOwner))
    end

    it "refuses an operationId that is a Ruby keyword, without declaring it" do
      emitter = generate(document("operationId: class\nresponses: { \"200\": { description: ok } }")) do |_, dir|
        expect(File.read(File.join(dir, "client.rb"))).to include("# cannot be generated: class")
      end

      expect(emitter.refusals.first.reason).to include("is a Ruby keyword")
    end

    it "refuses an operationId that cannot start a method name" do
      emitter = generate(document("operationId: 2faVerify\nresponses: { \"200\": { description: ok } }"))
      expect(emitter.refusals.first.reason).to include("cannot be a Ruby method name")
    end

    it "refuses two parameters that become one argument" do
      emitter = generate(document(<<~YAML))
        operationId: search
        parameters:
          - { name: foo-bar, in: query, schema: { type: string } }
          - { name: foo_bar, in: query, schema: { type: string } }
        responses: { "200": { description: ok } }
      YAML

      expect(emitter.refusals.first.reason).to include("two of its parameters are both called foo_bar")
    end

    # A member is reached through a dot and written as a label, and both take
    # a keyword. Refusing `end` would refuse every document with a date range
    # in it, for a problem Ruby does not have.
    it "keeps a property named for a keyword" do
      generate(named({ "Span" => "type: object\nproperties: { start: { type: string }, end: { type: string } }" })) do |emitter, dir|
        expect(File.read(File.join(dir, "types.rb"))).to include("end: String")
        expect(emitter.refusals).to be_empty
      end
    end

    # This one is not spare: the model is what casts, serializes and pattern
    # matches, and `to_h` is how it does two of those.
    it "refuses a property named for a method the model needs" do
      emitter = generate(named({ "Span" => "type: object\nproperties: { to_h: { type: string } }" }))
      expect(emitter.refusals.first.reason).to include(%(property "to_h" is a method the model needs))
    end

    it "refuses two properties that become one field" do
      emitter = generate(returning(<<~YAML))
        type: object
        properties:
          photoUrls: { type: array, items: { type: string } }
          photo_urls: { type: array, items: { type: string } }
      YAML

      expect(emitter.refusals.first.reason).to include("both become photo_urls")
    end
  end

  # Everything above is a mistake the generator knows how to look for. The
  # ones it does not are still in the file it wrote, so it reads it back.
  describe "the check that the output loads" do
    it "passes on a document it could translate" do
      emitter = generate(document("operationId: listThings\nresponses: { \"200\": { description: ok } }"))
      expect(emitter.broken).to be_nil
    end

    it "reports source Ruby cannot read, rather than leaving it to be required" do
      generate(document("operationId: listThings\nresponses: { \"200\": { description: ok } }")) do |emitter, dir|
        File.write(File.join(dir, "client.rb"), %(raise "the generated file was read back"\n))
        expect(emitter.send(:load_check, dir)).to include("the generated file was read back")
      end
    end
  end

  # `#/components/schemas/Pet` is a name in this document. `common.yaml#/Pet`
  # is a name in one the generator cannot see, and taking its last segment
  # would type the operation as whatever local schema happens to be called
  # Pet — a client that loads, runs, and decodes one schema as another.
  describe "a $ref" do
    it "into another file is refused" do
      emitter = generate(returning('$ref: "common.yaml#/components/schemas/Pet"'))
      expect(emitter.refusals.first.reason).to include("is not local to this document")
    end

    it "that resolves to nothing is refused" do
      emitter = generate(returning('$ref: "#/components/schemas/Nonexistent"'))
      expect(emitter.refusals.first.reason).to include("does not resolve")
    end
  end

  # One method returns one value, and several statuses are several types. The
  # document says which is which and the response carries the status, so the
  # method returns the union and the runtime reads the table.
  describe "more than one success response" do
    def two_successes(second)
      document(<<~YAML)
        operationId: createUser
        responses:
          "200":
            description: created
            content:
              application/json: { schema: { type: object, properties: { id: { type: integer } } } }
          "202":
            description: queued
            content:
              application/json: { schema: #{second} }
      YAML
    end

    let(:disagreeing) { two_successes("{ type: object, properties: { jobId: { type: string } } }") }

    it "casts each status to the type the document gave it" do
      generate(disagreeing) do |_, dir|
        source = File.read(File.join(dir, "client.rb"))
        expect(source).to include("into: Keiyaku::ByStatus[200 => CreateUserResult, 202 => CreateUser202Result]")
      end
    end

    it "returns the union of them" do
      generate(disagreeing) do |_, dir|
        signature = File.read(File.join(dir, "refused.rbs"))[/def create_user: .*/]
        expect(signature).to end_with("-> (CreateUserResult | CreateUser202Result)")
      end
    end

    it "is one type again when they are the same shape" do
      generate(two_successes("{ type: object, properties: { id: { type: integer } } }")) do |_, dir|
        expect(File.read(File.join(dir, "client.rb"))).to include("into: CreateUserResult")
      end
    end

    # `untyped` in a union takes the rest of it down with it, which is what
    # GitHub's stats endpoints are: an array of stats, or a 202 with a body
    # the document declines to describe.
    it "is untyped when the document left one of them open" do
      generate(two_successes("{}")) do |_, dir|
        signature = File.read(File.join(dir, "refused.rbs"))[/def create_user: .*/]
        expect(signature).to end_with("-> untyped")
        expect(File.read(File.join(dir, "client.rb"))).to include("202 => :any")
      end
    end
  end

  # `def find(until: nil)` is a method Ruby will define; `def find(until)` is
  # a file it will not read. So the one that can keep the document's name does.
  describe "a parameter named for a Ruby keyword" do
    def with_keyword(where)
      document(<<~YAML)
        operationId: listThings
        parameters:
          - { name: until, in: #{where}, required: true, schema: { type: string } }
        responses: { "200": { description: ok } }
      YAML
    end

    it "keeps the name when it is a query parameter" do
      generate(with_keyword("query")) do |emitter, dir|
        expect(emitter.refusals).to be_empty
        expect(File.read(File.join(dir, "client.rb"))).to include("query: %i[until!]")
        expect(File.read(File.join(dir, "refused.rbs"))).to include("def list_things: (until: String) ->")
      end
    end

    it "keeps it when it is a header parameter" do
      generate(with_keyword("header")) do |emitter, dir|
        expect(emitter.refusals).to be_empty
        expect(File.read(File.join(dir, "client.rb"))).to include(%(header: { "until" => :until! }))
      end
    end

    # A URL's segments are ordered, so a path parameter is positional, and a
    # positional argument cannot be called this at all.
    it "is refused when it is a path parameter" do
      emitter = generate(spec(<<~YAML))
        /things/{until}:
          get:
            operationId: getThing
            parameters:
              - { name: until, in: path, required: true, schema: { type: string } }
            responses: { "200": { description: ok } }
      YAML
      expect(emitter.refusals.first.reason).to include("which a positional argument cannot be")
    end
  end

  # A text body is a String sent as it stands. What the generator will not do
  # is decide that some other shape can be spelled as one.
  describe "a request body that is text" do
    def sending(content)
      document(<<~YAML).sub("get:", "post:")
        operationId: renderThing
        requestBody: { required: true, content: #{content} }
        responses: { "200": { description: ok } }
      YAML
    end

    let(:string) { "{ schema: { type: string } }" }

    it "is sent under the media type the document named" do
      generate(sending("{ text/x-markdown: #{string} }")) do |_, dir|
        expect(File.read(File.join(dir, "client.rb")))
          .to include(%(body: :text, content_type: "text/x-markdown"))
      end
    end

    it "is typed as a String" do
      generate(sending("{ text/plain: #{string} }")) do |_, dir|
        expect(File.read(File.join(dir, "refused.rbs"))).to include("def render_thing: (String body)")
      end
    end

    # GitHub's markdown endpoint takes text/plain and text/x-markdown for the
    # same string. The schemas differ only in the header, and the caller has
    # no way to say which, so the first is used and the rest are reported.
    it "takes the first of several, and says which" do
      emitter = generate(sending("{ text/plain: #{string}, text/x-markdown: #{string} }")) do |_, dir|
        expect(File.read(File.join(dir, "client.rb"))).to include(%(content_type: "text/plain"))
      end
      expect(emitter.notes).to include(a_string_including("sent as text/plain, of text/plain, text/x-markdown"))
    end

    # An object under text/csv is an encoding this generator does not know,
    # and passing the model through would send its #to_s.
    it "is refused when the document says it is not a string" do
      emitter = generate(sending("{ text/csv: { schema: { type: object, properties: { a: { type: string } } } } }"))
      expect(emitter.refusals.first.reason).to include("request body is text/csv")
    end
  end

  # The mechanism exists in the runtime, which evaluates a Proc for a type the
  # first time it casts one; without it the constant is referred to in the
  # middle of its own definition, and types.rb does not load at all.
  describe "a schema that contains itself" do
    let(:tree) do
      <<~YAML
        openapi: 3.1.0
        info: { title: Refused, version: "1" }
        servers: [{ url: "https://refused.test" }]
        components:
          schemas:
            Node:
              type: object
              properties:
                name: { type: string }
                children: { type: array, items: { $ref: "#/components/schemas/Node" } }
        paths:
          /nodes:
            get:
              operationId: getNode
              responses:
                "200":
                  description: ok
                  content:
                    application/json: { schema: { $ref: "#/components/schemas/Node" } }
      YAML
    end

    after { Object.send(:remove_const, :Recursive) if Object.const_defined?(:Recursive) }

    it "is typed lazily, and casts all the way down" do
      generate(tree, namespace: "Recursive") do |_, dir|
        load File.join(dir, "types.rb")
        cast = Recursive::Node.cast({ "name" => "root", "children" => [{ "name" => "leaf" }] })
        expect(cast.children.first).to be_a(Recursive::Node).and have_attributes(name: "leaf")
      end
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
