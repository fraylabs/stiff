# Parameters and request schemas

`src/router.bend` provides `Route{method, pattern, handler}`. A handler receives
`List<&2, Param>` and `Incoming`. `Router.route` selects the first matching route
for the exact method; otherwise it returns the same JSON 404/405 envelope as App,
with a deduplicated Allow header. `Router.param(name, params)` returns the first
matching parameter. Use unique parameter names in each pattern.

A `:name` occupies one nonempty slash-delimited path segment, for example
`/items/:id`. Literal segments, case, empty segments and trailing slashes remain
significant. Captured values are raw URI bytes expressed as text: `%2F` stays
`%2F`, never an extra slash. Query strings are not part of the path. This is not
filesystem path validation, wildcard routing or automatic percent decoding.

`src/schema.bend` validates a parsed JSON value without coercion:

| Constructor | Accepted values |
| --- | --- |
| `Text{min, max}` | String length in Unicode scalar values, inclusive Nat bounds |
| `UInt{min, max}` | Decimal unsigned 32-bit integer token, inclusive bounds |
| `Boolean{}` | JSON true/false |
| `Nullable{inner}` | Null or the inner schema |
| `Sequence{inner, min, max}` | Array with inclusive length bounds and matching elements |
| `Object{fields, strict}` | Object with `Field{name, required, schema}` entries; optional fields may be absent |

`strict=True` rejects undeclared object fields. Nullable and optional are separate:
required nullable fields still need to be present. UInt rejects negative values, fractional/exponent decimal representations and
strings; it is not a general floating-point validator. Validation sees the parsed
JSON representation: json-c normalizes the token `-0` to `0`, so UInt accepts it
when zero is in range. Original JSON number spellings are not preserved. JSON parsing has the existing bounded numeric/depth
contract. Define finite schemas in application code with unique field names and
sensible min/max bounds.

`Schema.validate(schema, value)` returns `Valid{}` or the first
`Invalid{path, code}`. Paths are arrays of field names/decimal array indices, so
names containing slash or tilde are unambiguous. `Schema.apply(schema, value,
next)` calls `next` only after validation, otherwise returns HTTP 422:

```json
{"error":{"code":"validation_failed","message":"Request validation failed","path":["tags","1"],"reason":"length"}}
```

Reasons include `required`, `type`, `length`, `integer`, `range`, and `unknown`.
Values are never echoed in the error. Validation uses a worklist over finite
schema/data; this implementation is tested native code, not a termination proof.

[The runnable API](../examples/validated-api.bend) combines path parameters,
nested/optional/nullable values and strict object validation:

```sh
./scripts/build-native.sh examples/validated-api.bend .cache/native/validated-api
./.cache/native/validated-api 127.0.0.1 8080
curl http://127.0.0.1:8080/items/abc
curl -H 'Content-Type: application/json' -d '{"name":"Brian","enabled":true,"count":1}' \
  http://127.0.0.1:8080/items/abc
```
