# Changelog

## 0.1.0 — unreleased

First cut. Generates a client, its value types and an RBS file from an OpenAPI
3.0 or 3.1 document.

- `Keiyaku::Client` DSL: one line per operation, real method arity
- `Keiyaku.model`: schemas as `Keiyaku::Model` subclasses — frozen, compared by
  value, copied with `#with`, pattern-matched. Casting a response ignores
  fields the document never mentioned; constructing one refuses a keyword it
  does not know, which is a typo rather than a server that has moved on
- `additionalProperties` is carried rather than dropped: a schema that says
  there may be properties it did not name gets a model that keeps them, read
  through the same `[]` as a property Ruby will not take through a dot, and
  written back under the names they arrived with. A schema that says nothing
  stays as strict as it was
- `style`/`explode` defaults (`form` for query, `simple` for path and header)
- `style: deepObject` query parameters, which go out as `filter[status]=live`.
  The style has one rendering in the specification and it is an object's, so
  that is what is generated: an array under `deepObject`, which is what Stripe
  writes on `expand`, is refused rather than guessed at, and so is a value
  nested a level deeper than the specification describes
- security is compiled per operation, from the operation's own requirement or
  the document's: alternatives, schemes required together, and `security: []`.
  Credentials are given by scheme name, and a scheme nothing can send refuses
  only the operations that require it
- API key in a header, query parameter or cookie; bearer and basic; OAuth 2
  and OpenID Connect access tokens, which are bearer tokens
- typed error bodies, mapped to `Keiyaku::ClientError` / `ServerError`; a
  request that never happened is a `Keiyaku::ConnectionError` whichever adapter
  it was, with the transport's own exception on `#cause`
- `timeout:` takes `{ open:, read: }` as well as one number for both
- constructs that cannot be translated faithfully are refused at generation
  time and raise `Keiyaku::Unsupported` if called
- inline schemas are named for where the document wrote them — the operation
  for a body or a response, the path down for a nested property — and two that
  are structurally identical stay two types, since the name a structural match
  keeps records where the generator walked rather than what the document says
- `oneOf`/`anyOf` with a `discriminator` becomes a `Keiyaku::OneOf`, including
  the document's `mapping`; without one it stays `:any` and says so
- `multipart/form-data` request bodies, with `Keiyaku::Upload` for file parts
- pagination, declared per operation with an `x-keiyaku-paginate` extension:
  `offset`, `page`, `cursor` and `link`, exposed as `#{name}_each`
- optional adapters for faraday and http.rb, required explicitly rather than
  depended on
- response header names are lower-cased before use, so an adapter that returns
  them any other way still decodes
- retry backoff has jitter
- `Keiyaku.model` takes its fields as a positional Hash, so a property named
  `from` or `required` cannot displace the option of the same name
- `anyOf` of a type and `null`, or of branches that all agree, keeps the type
  instead of degrading to `:any`
- operations with no `operationId` are named for their verb and path; two that
  would land on one name are both refused
- a document with no `servers` is a note, and building such a client without
  `base_url:` raises rather than failing later inside `URI`
- a tuple (`items` as a list, or `prefixItems`) no longer crashes the generator
- every Ruby name goes through one table, which refuses what Ruby will not
  take: a schema whose name is not a constant, an `operationId` that is a
  keyword, two schemas or two parameters or two properties that normalise onto
  one name
- several success responses have to agree on a type, or the operation is
  refused rather than casting one status's body into another's model
- `$ref` is resolved with JSON Pointer escaping and only within the document:
  one into another file is refused rather than silently naming a local schema
  that happens to end in the same segment
- a schema that contains itself is typed lazily instead of referring to a
  constant in the middle of its own definition
- the generator loads what it wrote, in another process, and reports a file
  Ruby cannot read back as a bug in itself rather than leaving it to be found
  at the first `require`
- a name the document chose reaches the generated files as data rather than as
  text spliced into them. A query parameter called `id]` used to close the
  `%i[]` it was written in and leave the rest of its own name to be read as
  Ruby — by the load check first, since that runs what it just wrote, and by
  every `require` of the client after it. The same for `deepObject` names and
  for the refusals written as comments, which are now kept to the one line a
  comment holds
- `x-keiyaku-paginate` keys are checked against the ones it has, so `pre:` for
  `per:` is a refusal rather than a walk that reads its page size off nothing
- `--module` has to be one Ruby constant, said against the flag rather than
  found later in a file that will not load
- a `Link` target that points at another origin raises instead of being
  followed with the client's credentials on it, and a relative one is resolved
  against the request that carried it rather than parsed as if it were whole
- which query and header parameters are required is declared once, as
  `required: %i[status]`, rather than marked with a bang on the end of each
  name. A document may name a parameter `notify!` itself, and the mark made
  that one required and sent it as `notify`
- a response keyed by a range — `4XX`, which is how a document describes its
  client errors in one go — is matched as one instead of read as the number 4.
  It used to be written into the client unquoted, which is not Ruby: the file
  did not parse, so every other operation in it was lost along with the one
  that carried the range. The runtime reads the exact code first, then the
  range that covers it, then `default`. A status that is none of the three is
  refused, which costs the one operation rather than the file
- an operation's second error response is named for its status where the shapes
  disagree, the way a second success response already was. Two errors of one
  shape are still one type; two of different shapes used to refuse the
  operation over the name they both derived
- a request body is optional unless the document required it, which is the
  specification's default and so is the DSL's: `body_required: true` is written
  down and its absence is the document's silence, rather than the other way
  round. It used to be a positional argument either way, so an endpoint that
  takes an empty body could only be called with a `nil` that went out as `null`
  under a Content-Type. Left out now it is no body at all
- a request body under a vendor media type keeps it: `application/vnd.acme+json`
  is built as the JSON its `+json` says it is, and sent under the name the
  document gave rather than relabelled `application/json`, which a server
  documenting the one is entitled to refuse. Where a document declares both,
  the plain type is taken and the choice is a note
- a parameter an operation declares again is the document narrowing the path
  item's — required here, optional elsewhere — rather than two parameters of
  one name. It used to be both, which is one Ruby keyword written twice, and
  the operation was refused for a duplicate the document never wrote
- `servers` on a path item or an operation is answered rather than ignored: it
  is refused unless the client's own server is among the ones it lists, since
  generating it would send that operation, and its credentials, to a host the
  document did not name. Several at the top level is a note saying which was
  taken, and a URL with variables in it is treated as no address at all rather
  than sent to a host called `{region}`
- an error body is cast to whatever type the document declared for that status
  rather than only to the ones that are a model. An error described as a list
  of problems arrives as that list; one described as a map was calling
  `Hash#cast`, and one the document left without a shape was calling
  `Symbol#cast` — a `NoMethodError` in place of the error the server sent,
  taking the status and the body with it, and matching no `rescue` the caller
  could have written. A body that does not fit the type it was declared with
  is kept as it arrived, since what answers a 502 is usually written by a
  proxy that never read the document
- a path or header parameter that is not a scalar goes out in the `simple`
  style the specification gives it: `1,2` for a list, and `role,admin` — or
  `role=admin` where the document wrote `explode`, which the operation now
  carries — for an object. It used to be whatever `#to_s` made of the value,
  so a list reached the server as a string with brackets and a space in it and
  an object as a Ruby Hash literal, neither of which anything reads back
- a path parameter is percent-encoded the way RFC 6570 says its style is: down
  to the unreserved characters, and inside the separators rather than over
  them. The whole segment used to go through `URI.encode_www_form_component`,
  which is the query's encoding and not a path's — a space became `+`, which
  in a path is a plus sign, and the comma between two elements of a list was
  encoded along with any comma inside one, so that neither could be told from
  the other at the far end
- `Retry-After` is read in both the forms RFC 7231 writes it: the seconds to
  wait, and the date the wait is over. The date raised an `ArgumentError` from
  the middle of the retry — out of the call the header was asking to have made
  again — and one already past now means go now rather than a negative sleep.
  A header in neither form is no instruction and leaves the wait to the backoff
