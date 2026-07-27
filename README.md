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
| RBS | none | 82 lines |
| shared runtime | — | 556 lines, written once |

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
Pet = Keiyaku.model({
  id: Integer, name: String, category: Category, photo_urls: [String],
  tags: [Tag], status: String
}, required: %i[name photo_urls])
```

The fields sit in a Hash of their own rather than as keywords beside
`required:`, because they are the API's names and not ours. A DIDComm message
has a property called `from`, which as a keyword would quietly have taken the
place of the option that maps JSON names.

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

## Unions, uploads, pages

A `oneOf` carrying a `discriminator` becomes a union that dispatches on it:

```ruby
Event = Keiyaku::OneOf[WidgetCreated, WidgetRetired, on: "kind",
                       map: { "created" => WidgetCreated, "retired" => WidgetRetired }]
```

and the RBS gets `type event = WidgetCreated | WidgetRetired`. Without a
discriminator there is nothing to dispatch on, so it stays `:any` and the run
says so — casting by trying each variant until one sticks would be a guess.

Some unions are only unions on paper, and those keep their type. `anyOf: [{type:
string}, {type: null}]` is how OpenAPI 3.1 says a field may be null, and a union
whose branches all resolve to the same type says nothing that type does not:
both become `String`. Neither is a guess, so neither is worth a note.

A `multipart/form-data` body is a model like any other, except that a property
with `format: binary` is typed `:upload`:

```ruby
post :upload_photo, "/widgets/{id}/photo", multipart: UploadPhotoBody, into: Widget

client.upload_photo(1, Widgets::UploadPhotoBody.new(
  file: File.open("kaya.png"), caption: "a dog", tags: %w[dog good]
))
```

A bare IO is wrapped in a `Keiyaku::Upload`, taking its filename from the path;
construct one yourself to set the filename or content type. An array property
becomes one part per element.

Pagination is declared in the document, because OpenAPI has no way to describe
it and a parameter named `page` is not evidence of anything:

```yaml
x-keiyaku-paginate: { by: offset, param: offset, size: limit, per: 100 }
```

```ruby
client.list_events_each(7)                 # => Enumerator of Event
client.list_events_each(7).lazy.first(20)  # one request, not all of them
client.list_events_each(7) { |event| ... }
```

Four strategies: `offset` and `page` advance a parameter until a page comes
back short, `cursor` reads the next cursor out of the response (`next:`, plus
`items:` when the response is an envelope), and `link` follows an RFC 8288
`Link: <...>; rel="next"` header. A hint naming a parameter the operation does
not have is refused rather than ignored, since what it would otherwise produce
is a client that pages forever.

## Transport

The default is `net/http`, and the gem has no dependencies. An adapter is one
method:

```ruby
def call(verb, uri, headers, body) = [status, headers, body]
```

Two are shipped without being loaded, or depended on:

```ruby
require "keiyaku/adapters/faraday"

client = Petstore::Client.new(adapter: Keiyaku::FaradayAdapter.new(connection))
```

`keiyaku/adapters/http` is the same for http.rb. Neither gem is a dependency
and neither will become one: a client for one API has no business choosing an
HTTP stack for the application around it. Response header names come back in
whatever case the library uses; the runtime lower-cases them, so an adapter
cannot get that wrong. Built-in retries back off exponentially with jitter and
honour `Retry-After`; if Faraday is already carrying faraday-retry, build the
client with `retries: 0` and let the middleware do it properly.

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

## Documents nobody wrote by hand

A document a server produced from its own routes tends to be missing the things
a hand-written one has, and the generator has to cope rather than refuse:

- **No `operationId`.** The verb and the path are then all there is to name a
  method with, so `POST /didcomm/pack/encrypted` becomes
  `post_didcomm_pack_encrypted` and a path parameter becomes `by_id`, which
  keeps `GET /things` and `GET /things/{id}` apart. Two operations that would
  still land on one name are a note, since the second would silently replace
  the first.
- **No `components`.** Every schema is then written out again under each
  operation. Two that are structurally identical become one model, named for
  where it first appeared — otherwise a document with nine operations over the
  same four shapes gets thirty-odd types.
- **No `servers`.** The address has to come from the application, so that is a
  note at generation time and a `Keiyaku::Error` naming the client if one is
  built without `base_url:`.

## Tests

`rake` regenerates the examples, validates their RBS, and runs the specs — 95
RSpec examples covering name mapping in both directions, nested and array
models, pattern matching, query array explosion, header parameters overriding
credentials, typed error bodies, binary and multipart request bodies,
discriminated unions, all four pagination strategies, and cast errors naming
the offending field.

Nothing is stubbed. The generated clients talk to a real HTTP server on a real
socket ([`spec/support/test_server.rb`](spec/support/test_server.rb)), which
also records what it was sent, so an example can assert on the request as well
as the response. A stubbed adapter would only agree with whatever the runtime
happened to do. The examples run in random order and each one starts with no
outstanding requests, so none of them depends on another having run first.

A second document, [`examples/widgets.yaml`](examples/widgets.yaml), exists to
keep the generator honest about not being fitted to the Petstore: OAS 3.1,
bearer auth, a `default` error response, and JSON fields that are already
snake_case (which the camelCase convention would otherwise guess wrong).

The optional adapters are covered by the same suite, over the same socket, when
faraday and http.rb happen to be installed. They are marked pending otherwise,
since neither is a dependency.

Saying they are optional is worth nothing unless something checks it, so CI
runs the suite a second time against
[`gemfiles/bare.gemfile`](gemfiles/bare.gemfile), which carries neither gem: a
stray `require` in the runtime fails there rather than on somebody's first
install. A third job builds the gem, installs it into an empty prefix, and
generates a client from outside the checkout — nothing from the working tree is
on the load path, which is what catches a file the gemspec forgot to list. The
matrix runs 3.2, the floor `Data.define` puts the gemspec at, through 4.0.

## Not done yet

- `deepObject` query parameters (`filter[status]=x`) are still refused, as are
  `explode: false` ones
- pagination has to be declared in the document; for a spec you do not control
  there is no hints file to declare it in
- regeneration overwrites wholesale; there is no merge strategy for hand edits,
  which bites hardest on the operations it refused and left you to write
- nothing is published; the gem builds and installs but has never been pushed,
  and the name is still provisional
