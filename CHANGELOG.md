# Changelog

## 0.1.0 — unreleased

First cut. Generates a client, its value types and an RBS file from an OpenAPI
3.0 or 3.1 document.

- `Keiyaku::Client` DSL: one line per operation, real method arity
- `Keiyaku.model`: schemas as `Data` subclasses, with lenient casting
- `style`/`explode` defaults (`form` for query, `simple` for path and header)
- API key, bearer and basic security schemes
- typed error bodies, mapped to `Keiyaku::ClientError` / `ServerError`
- constructs that cannot be translated faithfully are refused at generation
  time and raise `Keiyaku::Unsupported` if called
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
- structurally identical inline schemas are emitted as one model
- operations with no `operationId` are named for their verb and path; two that
  would land on one name are a note
- a document with no `servers` is a note, and building such a client without
  `base_url:` raises rather than failing later inside `URI`
- a tuple (`items` as a list, or `prefixItems`) no longer crashes the generator
