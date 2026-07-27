# openapi

An OpenAPI-to-Ruby client generator built on the premise that almost everything
existing generators emit is boilerplate that belongs in a runtime library.

Generating the [Swagger Petstore](examples/petstore.yaml) (OAS 3.0.4, 19
operations, 6 schemas):

| | `openapi-generator -g ruby` | this |
| --- | --- | --- |
| generated Ruby | 4,316 lines across 25 files | **68 lines across 2 files** |
| RBS | none | 82 lines |
| shared runtime | — | 373 lines, written once |

The whole client:

```ruby
module Petstore
  class Client < OpenAPI::Client
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
Pet = OpenAPI.model(
  id: Integer, name: String, category: Category, photo_urls: [String],
  tags: [Tag], status: String, required: %i[name photo_urls]
)
```

## Usage

```
ruby bin/generate examples/petstore.yaml Petstore examples/petstore
```

Three files land in the output directory: `types.rb`, `client.rb`, and an
`.rbs` carrying the type detail. Then:

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
and the schema fields. Everything else lives in `lib/openapi/runtime.rb` —
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

Calling one raises OpenAPI::Unsupported. Write those by hand.
```

## Tests

`rake` regenerates the examples, checks the RBS parses, and runs `test/e2e.rb`,
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
- `oneOf` — `OpenAPI::OneOf` exists in the runtime but the emitter does not
  wire it up, so unions currently degrade to `:any`
- regeneration overwrites wholesale; there is no merge strategy for hand edits
- retries back off exponentially with no jitter
- no gemspec — the runtime and the generator probably want to be two gems, and
  neither has a name yet
