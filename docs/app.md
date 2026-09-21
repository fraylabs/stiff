# Application building blocks

`src/app.bend` adds exact routes, middleware helpers, JSON parsing and required
text-field validation to the native server. It uses ordinary Bend functions;
there is no second runtime, registry or application service.

Build and run the standalone example:

```sh
make setup
./scripts/build-native.sh examples/app.bend .cache/native/app
./.cache/native/app 127.0.0.1 8080
```

From another terminal:

```sh
curl -H 'X-Demo-Access: allowed' http://127.0.0.1:8080/health
curl -H 'X-Demo-Access: allowed' -H 'Content-Type: application/json' \
  -d '{"name":"Brian"}' http://127.0.0.1:8080/greet
```

The example's header gate is synthetic middleware demonstration, **not an
authentication system**. It has no credentials, sessions or persistence. SIGINT
or SIGTERM uses the server's existing shutdown behavior.

## Routing

Create a route table for each request using a top-level factory:

```bend
def routes() -> List<App.Route>:
  [App.Route{"GET", "/health", health}, App.Route{"POST", "/greet", greet}]

def router(request: Web.Incoming) -> IO(Web.Reply):
  App.route(routes(), request)
```

Each handler has type `Web.Incoming -> IO(Web.Reply)`. The first exact method/path
match wins, including duplicate declarations. Missing paths get 404; a known
path with another method gets 405 and an `Allow` header with unique declared
methods. Methods and paths are case-sensitive. Query strings are excluded by
`Incoming.path`; paths are neither percent-decoded nor normalized. `/health`,
`/health/` and `/%68ealth` are distinct.

HEAD and OPTIONS require explicit routes; GET does not implicitly register HEAD.
There is no automatic CORS policy, path parameter extraction, wildcard matching
or route-table validation. Route declarations are trusted application code; use
valid HTTP method tokens and origin-form paths. Tables are searched linearly.

## Middleware

Middleware takes the next handler and a request, and returns `IO(Web.Reply)`.
`App.with_header(name, value, next, request)` adds a response header after the next
handler returns, including application error replies. Normal server response
header validation still applies. An outer wrapper runs before its inner handler
and receives the reply afterward.

`App.guard(allowed, status, code, message, next)` takes a `Unit -> IO(Web.Reply)`
continuation. False returns an error without evaluating that continuation. This
allows authorization, maintenance or other application policy to run before
routing, parsing or side effects. The caller supplies the policy; this helper
does not implement authentication or constant-time secret comparison.

The example wraps the gate with a response-header middleware, so both accepted
and rejected requests receive `X-Stiff: app`. Keep middleware inside `Web.serve`
to retain handler budgets and automatic completion. Long-running handlers still
need cooperative checkpoints as described in [server lifetimes](server.md).

## JSON validation and errors

`App.json_body(body, next)` parses a body and passes its JSON value to `next`.
Malformed JSON returns 400 with code `invalid_json` and a fixed message; parser
internals and submitted values are not echoed. This helper does not negotiate or
enforce Content-Type. Add that policy in middleware if your API requires it.

`App.required_text(field, min, max, value)` requires a top-level JSON object and a
string field whose Unicode code-point count is between the inclusive Nat bounds.
It returns `TextValid{text}` or `TextInvalid{field, reason}`:

| Reason | Meaning |
| --- | --- |
| `object_required` | Top-level value is not an object |
| `required` | Field is absent |
| `type` | Field exists but is not a string, including null |
| `length` | Text is outside the supplied inclusive bounds |

There is no trimming, Unicode normalization, grapheme counting, coercion or
rejection of extra fields. The JSON parser's existing last-value-wins rule for
duplicate keys remains in effect. These are individual validation primitives,
not a general schema system. The caller must only run its business operation
after matching `TextValid`; the example and tests exercise this sequence.

`App.validation_error(field, reason)` returns 422:

```json
{"error":{"code":"validation_failed","message":"Request validation failed","field":"name","reason":"required"}}
```

`App.error(status, code, message)` supplies the common application envelope
`{"error":{"code":"...","message":"..."}}`. Messages are JSON-encoded; supply
public, stable messages rather than raw exceptions or secrets. Applications may
return their own reply bodies. HTTP parser/transport rejection and the lower-level
server's response/encoding fallbacks retain their existing formats; this module
does not intercept errors before application dispatch or catch process failures.

`make test` compiles and runs the app from a separate temporary directory without
source or tools on PATH. It checks success, Unicode bounds, route precedence,
unique allowed methods, middleware rejection before parsing, malformed JSON,
validation failures, and recovery. It runs in normal and diagnostic sanitizer CI.
