# keiyaku

契約 — an OpenAPI-to-Ruby client generator built on the premise that almost
everything existing generators emit is boilerplate that belongs in a runtime
library. A spec is a contract; the generated code should be the part of it that
is actually specific to your API, and nothing else.

Generating the [Swagger Petstore](examples/petstore.yaml) (OAS 3.0.4, 19
operations, 6 schemas):

| | `openapi-generator -g ruby` | this |
| --- | --- | --- |
| generated Ruby | 4,316 lines across 25 files | **68 lines across 2 files** |
| RBS | none | 82 lines |
| shared runtime | — | 374 lines, written once |

The whole client:

```ruby
module Petstore
  class Client < Keiyaku::Client
    server "https://petstore3.swagger.io/api/v3"
    security({ header: "api_key" })

    put    :update_pet, "/pet", body: Pet, into: Pet
    post   :add_pet, "/pet", body: Pet, into: Pet
    get    :find_pets_by_status, "/pet/findByStatus", query: %i[status!], into: [Pet]
    get    :get_pet_by_id, "/pet/{petId}", into: Pet
    delete :delete_pet, "/pet/{petId}", header: { "api_key" => :api_key }
    get    :get_inventory, "/store/inventory", into: { String => Integer }
    post   :create_users_with_list_input, "/user/createWithList", body: [User], into: User
    # ...
  end
end
```

and its types:

```ruby
Pet = Keiyaku.model(
  id: Integer, name: String, category: Category, photo_urls: [String],
  tags: [Tag], status: String, required: %i[name photo_urls]
)
```

## Usage

```ruby
gem "keiyaku"
```

One gem, no dependencies. The runtime is what an application loads; the
generator is a separate file that only the executable pulls in, so nothing
that merely calls an API ever loads it.

```
keiyaku petstore.yaml --module Petstore --out lib/petstore
```

Three files land in the output directory: `types.rb`, `client.rb`, and an
`.rbs` carrying the type detail. Check them in — they are source, not build
output, and reading the diff is how you see what changed in an API. Then:

```ruby
client = Petstore::Client.new(auth: ENV["PETSTORE_KEY"])

pet = client.get_pet_by_id(5)          # => Petstore::Pet
pet.photo_urls                         # camelCase mapped to snake_case
pet.with(name: "Nori")                 # it's a Data, so this is free

case client.find_pets_by_status(status: "available")
in [{ name:, category: { name: "Dogs" } }, *] then ...
end
```

## How it splits

Generated code carries only what is specific to one API: the operation table
and the schema fields. Everything else lives in `lib/keiyaku/runtime.rb` —
transport, auth, the `style`/`explode` parameter rules, body encoding, response
casting, error mapping, retries. The contract between the two is one method,
`Client#__invoke`, so the runtime can change without regenerating anything.

Terseness in `client.rb` costs nothing in tooling because the emitted RBS
carries the full signature:

```rbs
def find_pets_by_status: (status: String) -> Array[Pet]
def update_pet_with_form: (Integer pet_id, ?name: String?, ?status: String?) -> Pet
def get_inventory: () -> Hash[String, Integer]
```

The gem ships `sig/keiyaku.rbs` for the runtime itself, so a generated
`class Client < Keiyaku::Client` resolves rather than dangling. `rake rbs`
validates the examples against it, which is the check that would have caught
the generated RBS being subtly unresolvable.

The DSL builds real methods with real arity — `get :get_pet_by_id,
"/pet/{petId}"` defines `get_pet_by_id(pet_id)`, and calling it wrong raises
`ArgumentError` at the call, not a confusing failure inside the client. A `!`
suffix marks a required parameter: `query: %i[status! limit]`.

## Refusing rather than guessing

The failure mode that matters is a generator emitting plausible code that is
subtly wrong. When this one cannot translate a construct faithfully it says so
at generation time and emits an operation that raises:

```
2/3 operations, 3 files

refused to generate 1 operation(s):
  - list_widgets: query parameter filter uses style=deepObject

Calling one raises Keiyaku::Unsupported. Write those by hand.
```

## Tests

`rake` regenerates the examples, validates their RBS, and runs `test/e2e.rb`,
which drives the generated clients against a real socket — 33 checks covering
name mapping in both directions, nested and array models, pattern matching,
query array explosion, header parameters overriding credentials, typed error
bodies, binary request bodies, and cast errors naming the offending field.

A second spec, [`examples/widgets.yaml`](examples/widgets.yaml), exists to keep
the generator honest about not being fitted to the Petstore: OAS 3.1, bearer
auth, a `default` error response, and JSON fields that are already snake_case
(which the camelCase convention would otherwise guess wrong).

## Not done yet

- `multipart/form-data` — the last common construct that still gets refused
- pagination — nothing at all; needs a `paginate:` hint and an `Enumerator`
- `oneOf` — `Keiyaku::OneOf` exists in the runtime but the emitter does not
  wire it up, so unions currently degrade to `:any`
- regeneration overwrites wholesale; there is no merge strategy for hand edits
- retries back off exponentially with no jitter
- nothing is published; the gem builds and installs but has never been pushed,
  and the name is still provisional
