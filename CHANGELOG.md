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
