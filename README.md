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
    security({ petstore_auth: :bearer, api_key: { header: "api_key" } })

    put    :update_pet, "/pet", body: Pet, into: Pet, security: :petstore_auth
    post   :add_pet, "/pet", body: Pet, into: Pet, security: :petstore_auth
    get    :find_pets_by_status, "/pet/findByStatus", query: %i[status!], into: [Pet], security: :petstore_auth
    get    :get_pet_by_id, "/pet/{petId}", into: Pet, security: [[:api_key], [:petstore_auth]]
    delete :delete_pet, "/pet/{petId}", header: { "api_key" => :api_key }, security: :petstore_auth
    get    :get_inventory, "/store/inventory", into: { String => Integer }, security: :api_key
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
client = Petstore::Client.new(auth: { api_key: ENV["PETSTORE_KEY"] })

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

A body the document describes as text goes out as it stands, under the media
type the document named, and so does a binary one — neither is JSON, and the
only thing the generator has to know is what to put in the header.

An operation whose statuses are different types is all of them. GitHub answers
a request for a repository's contributor stats with the stats, or with a 202
meaning it is still counting; the document says which type belongs to which
status and the response carries the status, so nothing has to be guessed:

```ruby
post :import_widgets, "/widgets/import", body: :text, content_type: "text/csv",
     into: Keiyaku::ByStatus[200 => [Widget], 202 => ImportQueued]
```

and the RBS returns `(Array[Widget] | ImportQueued)`, which is a caller that
has to look. A status the document did not describe is passed through undecoded
rather than cast into a type the server never claimed to be sending.

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
7/8 operations, 3 files

refused to generate 1 operation(s):
  - list_widgets: query parameter expand uses style=deepObject on a schema that is not an object

Calling one raises Keiyaku::Unsupported. Write those by hand.
```

What it refuses is anything where the generated code would be a guess: a name
Ruby will not take or that two things want at once, a `$ref` into a file it
cannot see, a body in an encoding it does not know, a security scheme it has
no way to send. Then, because the mistakes it does not know to look for
are still in the file it wrote, it reads that file back in another process and
reports what will not load as a bug in itself.

The line it draws is the specification's, not a shortlist of what has been
implemented. `deepObject` is the clearest case. Its one row in OpenAPI's table
of styles is an object, exploded, and that is generated:

```ruby
client.search_widgets(q: "kaya", filter: Widgets::SearchWidgetsFilter.new(status: "live"))
# GET /widgets/search?q=kaya&filter[status]=live
```

The array and primitive columns of that row are written n/a, so an array under
`deepObject` — which is what Stripe writes on `expand`, on 351 parameters — is
not something the specification is quiet about, it is something the
specification says has no spelling. `expand[]=a` and `expand[0]=a` are both
plausible and neither is described, so that one is refused. Stripe's document
generates 352 of its 619 operations, and every one of the 267 it does not is
held up by exactly this.

## Credentials

An operation is authenticated the way the document says that operation is
authenticated — which is not always the way the one above it is. The Petstore
declares two schemes and uses them differently across nineteen operations, so
credentials arrive by the name the document gave the scheme:

```ruby
client = Petstore::Client.new(auth: { api_key: ENV["PETSTORE_KEY"] })

client.get_inventory          # api_key: ...
client.get_pet_by_id(5)       # api_key: ..., the first of two alternatives
client.add_pet(pet)           # raises: this one documents petstore_auth
```

A single value is allowed where the document declares one scheme, since naming
it would be ceremony. With two it is refused, because assigning it to whichever
came first is exactly how a client ends up sending an API key to the endpoints
that document OAuth. A client built with no credentials at all is taken at its
word and sends none: plenty of servers do not enforce what their document
declares, and that is not this library's call to make.

## Documents nobody wrote by hand

A document a server produced from its own routes tends to be missing the things
a hand-written one has, and the generator has to cope rather than refuse.
[`examples/sidecar.json`](examples/sidecar.json) is one, checked in exactly as
the service prints it — ten routes, and every one of these true at once:

- **No `operationId`.** The verb and the path are then all there is to name a
  method with, so `POST /didcomm/pack/encrypted` becomes
  `post_didcomm_pack_encrypted` and a path parameter becomes `by_id`, which
  keeps `GET /things` and `GET /things/{id}` apart. Two operations that would
  still land on one name are both refused, since whichever was written second
  would take the method and every call meant for the other would go to a route
  it does not name.
- **No `components`.** Every schema is then written out again under each
  operation, and each copy becomes its own model named after the operation it
  was written under. Ten routes over four shapes is seventy-one types rather
  than the thirty-one that matching them up by structure would give, and the
  forty extra are the price of never having chosen a name — see below.
- **No `servers`.** The address has to come from the application, so that is a
  note at generation time and a `Keiyaku::Error` naming the client if one is
  built without `base_url:`.

A document like this is worth more as a test than one written for the purpose,
because it was not written for the purpose. Every defect found in the generator
so far came from pointing it at that file rather than at the two below.

## Where the names come from

Every type is named by reading the document, and the generator never picks
between two names that both fit. Where the document names a type — anything in
`components/schemas` — the name is its own. Where it does not, the position the
schema was written in names it: an operation's request body is that operation
plus `Body`, a success response plus `Result`, an error plus `Error`, and a
property nested inside one of those is its path down from it.

Two schemas that happen to be structurally identical are still two types. This
is the rule that costs the most — Stripe writes out all 601 of its request
bodies inline, and matching them up drops 5,014 models to 2,306 — and it is
still the right way round, because the name a structural match keeps is a
record of where the generator walked first rather than of anything in the
document. That is how 56 unrelated Stripe operations came to share a body type
called `PostAccountsAccountLoginLinksBody`, 25 more a type called after a card
mandate, and how the sidecar's `POST /did/resolve` came to declare its own
success type as its 400 body — a caller rescuing the error got a value whose
class said the call had succeeded.

The one thing that is still shared is a name derived twice. An operation's 400
and its 404 are both `#{name}Error`, and where the document gives them the same
shape they are one model; where it does not, the operation is refused rather
than one of the two silently losing its body.

## Tests

`rake` regenerates the examples, validates their RBS, and runs the specs — 176
RSpec examples covering name mapping in both directions, nested and array
models, pattern matching, query array explosion, header parameters overriding
credentials, per-operation security, typed error bodies, binary, text and
multipart request bodies, discriminated unions, responses cast by their status,
all four pagination strategies, and cast errors naming the offending field.

Nothing is stubbed. The generated clients talk to a real HTTP server on a real
socket ([`spec/support/test_server.rb`](spec/support/test_server.rb)), which
also records what it was sent, so an example can assert on the request as well
as the response. A stubbed adapter would only agree with whatever the runtime
happened to do. The examples run in random order and each one starts with no
outstanding requests, so none of them depends on another having run first.

A second document, [`examples/widgets.yaml`](examples/widgets.yaml), exists to
keep the generator honest about not being fitted to the Petstore: OAS 3.1,
bearer auth, a `default` error response, and JSON fields that are already
snake_case (which the camelCase convention would otherwise guess wrong). Its
`POST /widgets/import` holds the three things a document is entitled to say
and Ruby is awkward about — a text body, a parameter called `until`, and two
success statuses that are two types — because each of them was a refusal until
GitHub's document turned one up. It also carries both sides of the `deepObject`
line at once: `GET /widgets/search` takes one on an object and is generated,
`GET /widgets` takes one on an array and is the document's single refusal.

A third, [`examples/sidecar.json`](examples/sidecar.json), was not written for
this at all — see above. Its client is generated and its RBS validated on every
run like the others, and [`spec/sidecar_spec.rb`](spec/sidecar_spec.rb) asserts
that every one of its types is named after the operation it was written under,
which is the whole of the naming rule on a document that names nothing itself.

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
- pagination has to be declared in the document; for a spec you do not control
  there is no hints file to declare it in
- regeneration overwrites wholesale; there is no merge strategy for hand edits,
  which bites hardest on the operations it refused and left you to write
- nothing is published; the gem builds and installs but has never been pushed,
  and the name is still provisional
