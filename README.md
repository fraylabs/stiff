# Stiff

HTTP building blocks for **Bend 2**. Write a Bend `IO` program and run it as a
native executable or with Stiff's Node host. An early experiment by Fray.

Stiff pairs pure Bend request definitions and response policy with libcurl/json-c
or Node's HTTP(S) transport and JSON parser. It supports GET and JSON POST, deadlines,
cancellation, bounded response bodies, and explicit HTTP status handling.

**Status:** experimental source prototype, pinned to Bend **2.0.20**. Bend entry
points, an experimental native CPU backend and a JavaScript API are supported.
Native executables require libcurl and json-c, but **do not require Node**.
This is a native-path proof, not a portable binary release or a production-readiness claim.
The upstream Bun IO runner and npm distribution are not supported yet.

## Native build (no Node required)

Install the standalone **Bend 2.0.20** compiler, Clang, pkg-config, libcurl
development files and json-c development files. Then:

```sh
./scripts/build-native.sh examples/get-json.bend .cache/native/get-json
./.cache/native/get-json https://httpbin.org/json
```

Set `BEND` to a compiler path if it is not on PATH. The same program prints
`HTTP 200` and `Sample Slide Show`. For the source checkout/Node toolchain below,
the alternative builder is:

```sh
npm run build:native -- examples/get-json.bend .cache/native/get-json
npm run test:native
```

The alternative builder and test harness use Node; the resulting program does
not. See [native build and verification notes](docs/native.md) for dependencies,
backend differences and the reproduced upstream sanitizer failure.

## Run it

Requires Node **26+**, Git, and OpenSSL for the local TLS tests.

```sh
git clone https://github.com/fraylabs/stiff.git
cd stiff
npm run setup
npm test
npm run bend -- examples/get-json.bend
```

Setup fetches the upstream Bend source into ignored `.cache/bend/` and checks its
exact commit, `a5269a6b2c5ccd6752b66df4bc6f60678b4f49bc`. It changes no global tools
and installs no npm dependencies. The source loader is required because this
Bend release does not package it with the standalone binary. Node may print
warnings about upstream module loading; that integration remains experimental.

## Write a Bend program

The runnable [example](examples/get-json.bend) sends an HTTPS request, matches the
result, reads the nested JSON `slideshow.title` field and prints it. Pass another
URL as an argument:

```sh
npm run bend -- examples/get-json.bend https://httpbin.org/json
# HTTP 200
# Sample Slide Show
```

The main operation uses standard Bend `IO` syntax:

```python
def main() -> IO(Unit):
  do IO<Unit>:
    response : Net.JsonResult <- Net.Stiff.send_json(Http.get("https://httpbin.org/json"))
    show(response)
```

Here `Http` imports `src/http.bend` and `Net` imports `src/io.bend` using paths
relative to your `.bend` file. The example includes these imports and `show`.

| Operation | Bend result |
| --- | --- |
| `Net.Stiff.send(request)` | `HttpOk{Response{status, body}}` or `HttpError{code, message}` |
| `Net.Stiff.send_json(request)` | `JsonOk{status, value}` or `JsonError{code, message}` |

`Json.field(key, value)` returns `Some{value}` or `None{}`. JSON values use explicit
`JsonNull`, `JsonBool`, `JsonNumber`, `JsonString`, `JsonArray` and `JsonObject`
constructors. Array items and object entries are Bend lists. Numbers contain a
decimal string after the host parser, with no arbitrary-precision guarantee.
Node uses JavaScript number precision; native json-c uses its own numeric spelling
and rejects integer tokens outside the JavaScript safe-integer range. Duplicate
keys use the last value. The bridge rejects nonfinite numbers and nesting deeper
than 128 levels with `json_number_range` and `json_too_deep` errors.

The Node runner supports sequential `IO.pure`/`IO.bind`/`do`, `IO.print`, `IO.write`,
`IO.print_err`, `IO.args`, `IO.sleep`, `IO.die`, Stiff HTTP and JSON parsing. Other
effects fail explicitly. Channels, spawned tasks, file IO, and native sockets
are not implemented by this runner. Ctrl-C aborts the active HTTP call or sleep,
stops continuation delivery, and exits with code 130. The Bend API currently has
no custom-header option; that remains available through the JavaScript API.

The runner uses the pinned compiler's IO operation representation and awaits
asynchronous effects in Node. It does not modify upstream source. It runs trusted
program source and foreign effects; it is not a sandbox. Native compilation uses
Bend's C runtime and Stiff's C effects, documented separately in the native notes.

## JavaScript API

```js
import { Http, sendJson } from './src/node.mjs';

const request = Http.with_timeout(5000,
  Http.get('https://httpbin.org/json'));
const response = await sendJson(request);

console.log(response.status, response.ok, response.data);
```

Run a host program with:

```sh
node --import ./.cache/bend/bend2/main.ts your-program.mjs
```

`Http.get`, `Http.post_json`, `Http.with_timeout`, `Http.with_max_bytes`, and
`Http.is_success` execute the actual Bend definitions from `src/http.bend`.
`send` and `sendJson` execute network effects in the Node host.

```js
const controller = new AbortController();
const request = Http.post_json('https://httpbin.org/post', JSON.stringify({ hello: 'Bend' }));
const response = await sendJson(request, {
  signal: controller.signal,
  headers: { 'x-example': 'stiff' },
});
```

## Behavior

- Default deadline: 10 seconds, covering headers and response body.
- Default response limit: 1 MiB of decoded transport bytes, before UTF-8 decoding.
- Only HTTP(S) URLs are accepted; embedded URL credentials are rejected.
- HTTPS uses Node's certificate verification. Stiff offers no TLS bypass option.
- Stiff adds no retry loop and does not follow redirects. A failed or cancelled
  POST may already have reached the server; cancellation does not undo it.
- HTTP 3xx, 4xx and 5xx are returned as responses. `ok` means status 200–299.
- `send` returns `{ status, ok, headers, body }`; `sendJson` adds `data`.
- Bodies must be UTF-8. JSON POST bodies must be valid JSON before sending.
- Headers are a plain object; this prototype does not preserve repeated headers
  as separate values. There is no cookie jar, streaming API or binary-body API.
- Requests are snapshotted before IO. Timeout and size limits must be positive
  integers no larger than 2,147,483,647.

Failures throw `StiffError` with a stable `code`: `invalid_request`,
`invalid_json_request`, `network`, `timeout`, `cancelled`, `body_too_large`,
`invalid_utf8`, or `invalid_json_response`. Detailed network errors are retained
as `cause`; avoid logging them with sensitive request URLs or headers.

This is a general network client, not an SSRF filter. Applications accepting
untrusted destinations need their own destination policy.

## What is checked

`npm test` imports `src/PROOF.bend` through the pinned checker and exercises the
real Bend/Node boundary. Three pure laws cover setting request limits and
preserving the body limit when changing the deadline. A deliberately false
proof must fail. Local HTTP and HTTPS fixtures exercise real transport,
certificate rejection and explicit trust, JSON, cancellation, deadlines,
redirects, size limits and UTF-8 errors. Tests use ephemeral certificates and
require no provider credentials or external API.

Bend IO integration tests run real `.bend` files through the compiler and runner,
including GET/POST, nested JSON lookup, transport errors, deadline/size limits,
TLS trust, unsupported effects, asynchronous sleep and SIGINT cancellation. They
also check that cancellation does not print the interrupted continuation's result.

`npm run test:native` builds and copies real executables outside the checkout,
runs them with no Node on PATH, and checks the native HTTP/JSON boundary and
failure paths against local fixtures.

These proofs do **not** verify TLS, libcurl, Node fetch, JSON parsing, the loader, or the
Bend compiler. The host adapter and compiler remain trusted dependencies.

## Direction

The native path is working alongside the Node runner. Next candidates are
request headers in the Bend API, a stable distribution format and broader backend
conformance. Compiler upgrades remain deliberate because both adapters depend on
compiler internals; sanitizer compatibility remains unresolved upstream.

Contributions should include a runnable example or a failing case, clearly
separate pure laws from host behavior, and keep compiler upgrades explicit.

## License

Stiff is MIT licensed. Bend is an independent upstream project; setup retrieves
its source with its own license notices intact. No upstream source is vendored
or relicensed in this repository.
