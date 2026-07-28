# keiyaku

[![ci](https://github.com/onyxblade/keiyaku/actions/workflows/ci.yml/badge.svg)](https://github.com/onyxblade/keiyaku/actions/workflows/ci.yml)

契約 — an OpenAPI-to-Ruby client generator built on the premise that almost
everything existing generators emit is boilerplate that belongs in a runtime
library. A spec is a contract; the generated code should be the part of it that
is actually specific to your API, and nothing else.

Generating the [Swagger Petstore](examples/petstore.yaml) (OAS 3.0.4, 19
operations, 6 schemas):

| | `openapi-generator -g ruby` | this |
| --- | --- | --- |
| generated Ruby | 4,316 lines across 25 files | **67 lines across 2 files** |
| RBS | none | 88 lines |
| shared runtime | — | 939 lines, written once |

## Install

```ruby
gem "keiyaku"
```

One gem, no dependencies. The runtime is what an application loads; the
generator is a separate file that only the executable pulls in, so nothing
that merely calls an API ever loads it.

## Generate

```
keiyaku petstore.yaml --module Petstore --out lib/petstore
```

Three files land in the output directory: `types.rb`, `client.rb`, and an
`.rbs` carrying the type detail. Check them in — they are source, not build
output, and reading the diff is how you see what changed in an API.

`client.rb` is a table of operations, one line each:

```ruby
module Petstore
  class Client < Keiyaku::Client
    server "https://petstore3.swagger.io/api/v3"
    security({ petstore_auth: :bearer, api_key: { header: "api_key" } })

    put    :update_pet, "/pet", body: Pet, into: Pet, security: :petstore_auth
    post   :add_pet, "/pet", body: Pet, into: Pet, security: :petstore_auth
    get    :find_pets_by_status, "/pet/findByStatus", query: %i[status], required: %i[status], into: [Pet], security: :petstore_auth
    get    :get_pet_by_id, "/pet/{petId}", into: Pet, security: [[:api_key], [:petstore_auth]]
    delete :delete_pet, "/pet/{petId}", header: { "api_key" => :api_key }, security: :petstore_auth
    get    :get_inventory, "/store/inventory", into: { String => Integer }, security: :api_key
    post   :create_users_with_list_input, "/user/createWithList", body: [User], into: User
    # ...
  end
end
```

`types.rb` is a value type per schema:

```ruby
Pet = Keiyaku.model({
  id: Integer, name: String, category: Category, photo_urls: [String],
  tags: [Tag], status: String
}, required: %i[name photo_urls])
```

and the RBS beside them carries the full signature, so terse Ruby costs nothing
in tooling:

```rbs
def find_pets_by_status: (status: String) -> Array[Pet]
def update_pet_with_form: (Integer pet_id, ?name: String?, ?status: String?) -> Pet
def get_inventory: () -> Hash[String, Integer]
```

## Call

```ruby
client = Petstore::Client.new(auth: { api_key: ENV["PETSTORE_KEY"] })

pet = client.get_pet_by_id(5)          # => Petstore::Pet
pet.photo_urls                         # camelCase mapped to snake_case
pet.with(name: "Nori")                 # models are frozen values; copies are cheap

case client.find_pets_by_status(status: "available")
in [{ name:, category: { name: "Dogs" } }, *] then ...
end
```

Methods have real arity — `get_pet_by_id(5)` with the wrong number of arguments
raises `ArgumentError` at the call, not somewhere inside the client.
Credentials are given by the name the document gave the scheme, and each
operation is authenticated the way the document says *that* operation is.

## What it covers

- **Models** — frozen value types, compared by value, copied with `#with`,
  pattern-matched. Names are mapped in both directions; `additionalProperties`
  are carried rather than dropped, and round-trip losslessly.
- **Parameters** — `form` and `deepObject` query styles, `simple` for path and
  header, with the specification's `explode` defaults. `required:` says which a
  caller has to pass.
- **Bodies** — JSON, a server's own `+json` media type, text, binary, and
  `multipart/form-data` with file uploads.
- **Responses** — cast per status, including by range; `Keiyaku::ByStatus` for
  an operation whose statuses are different types; typed error bodies mapped to
  `Keiyaku::ClientError` / `ServerError`.
- **Unions** — a `oneOf`/`anyOf` with a `discriminator` becomes a
  `Keiyaku::OneOf` that dispatches on it.
- **Security** — compiled per operation: alternatives, schemes required
  together, `security: []`. API key in a header, query or cookie; bearer,
  basic, OAuth 2 and OpenID Connect tokens.
- **Transport** — `net/http` by default, autoloaded only if used; adapters for
  faraday and http.rb ship without either being a dependency. Retries back off
  with jitter and honour `Retry-After`; `timeout:` takes `{ open:, read: }`; a
  request that never happened is a `Keiyaku::ConnectionError` whatever is
  underneath.

## What it refuses

The failure mode that matters is a generator emitting plausible code that is
subtly wrong. When this one cannot translate a construct faithfully it says so
at generation time and emits an operation that raises:

```
8/9 operations, 3 files

refused to generate 1 operation(s):
  - list_widgets: query parameter expand uses style=deepObject on a schema that is not an object

Calling one raises Keiyaku::Unsupported. Write those by hand.
```

A name Ruby will not take, a `$ref` into a file it cannot see, an encoding it
does not know, a security scheme it has no way to send, an operation pointing
at a server the client does not declare — each is refused rather than guessed
at. The line it draws is the specification's: `deepObject` on an object is
described and is generated, `deepObject` on an array is written n/a in
OpenAPI's own table and is not.

## Not done yet

- `explode: false` query parameters are still refused, and so is every query
  style but `form` and `deepObject` — `spaceDelimited` and `pipeDelimited` are
  described by the specification and simply have not been written yet, which is
  not the same as `deepObject` on an array, which never will be
- the document has to be one file. A `$ref` into another is refused rather
  than resolved, so anything split up has to be bundled first — by something
  else, since nothing here fetches a URL to find out what a type is
- `readOnly` and `writeOnly` are not read, so one schema is one model in both
  directions. Until they are, `required:` cannot be enforced when a model is
  constructed — the Petstore's `Pet.id` is required in a response and has no
  business being set on a request, and one flag cannot mean both
- `enum` values are not carried: the type they restrict is generated and the
  list itself is not checked in either direction
- there is no pagination. OpenAPI describes none, and a parameter named `page`
  is not evidence of anything, so walking an operation has to be declared —
  which for a document you did not write means a hints file, and there is none.
  Until there is, the loop over the pages belongs to the application
- a client is built for one server. An operation that overrides it is refused
  rather than sent somewhere else, and server variables have no substitution,
  so both are for the application to supply through `base_url:`
- regeneration overwrites wholesale; there is no merge strategy for hand edits,
  which bites hardest on the operations it refused and left you to write

## More

[DESIGN.md](DESIGN.md) is the long version: how the generated code and the
runtime split, what happens to unions, uploads and open models, where type
names come from, why a construct gets refused, and what the test suite is
pointed at. [CHANGELOG.md](CHANGELOG.md) is what has changed.

MIT licensed.
