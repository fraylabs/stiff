# Stiff

Native HTTP(S) client, HTTP server and JSON building blocks for **Bend 2**. Write a Bend `IO`
program, compile it to an executable, and run it with libcurl and json-c.

**Status:** experimental, pinned to Bend **2.0.20**. No Node or npm dependency.
This is not a static binary distribution or a production-readiness claim.

## Get started

You need Clang, make, pkg-config, libcurl development files (7.85 or newer),
json-c development files, libevent **2.1.12+** for server builds/tests, and OpenSSL
for tests. Python **3.11.8+** is used only
for setup and tests; it is not part of the application runtime. These Python
tools use the standard library and require no packages or virtual environment.

```sh
git clone https://github.com/fraylabs/stiff.git
cd stiff
make setup
make test
make build
./.cache/native/get-json https://httpbin.org/json
# HTTP 200
# Sample Slide Show
```

`make setup` downloads the standalone Bend 2.0.20 release into `.cache/toolchain`,
checks its pinned SHA-256 before extraction, and changes no global installation.
It supports macOS/Linux release archives on arm64 and x64. The source revision
for this compiler release is `a5269a6b2c5ccd6752b66df4bc6f60678b4f49bc`.

If you already have Bend 2.0.20, skip setup and set `BEND` to its executable.
`CC` can select Clang. To compile another program:

```sh
./scripts/build-native.sh your-program.bend .cache/native/your-program
```

Executables link dynamically to libcurl and json-c. The target machine needs
those libraries and a CA trust store, but not Bend or Python. Build on the
platform where the executable will run.

## Run a native HTTP server

```sh
make server
./.cache/native/server 127.0.0.1 8080
```

The [example](examples/server.bend) routes `GET /health`, `POST /echo` and `POST /inspect`,
and constructs JSON responses from Bend values. Handlers run concurrently; SIGINT/SIGTERM stops admissions and
drains dispatched requests. Build your handler as `Incoming -> IO(Reply)` and
pass it to `Web.serve(~handler)` after listening.

See [server API and limits](docs/server.md) for configuration, headers, deadlines
and shutdown semantics. This version uses HTTP with TLS at a reverse proxy.

## Use Stiff in your own project

Copy [examples/auth-client](examples/auth-client) into a separate project and run
`make setup build` there. It fetches Stiff directly from GitHub at the exact
revision in `stiff.rev`, installs the pinned compiler, and builds a native client.
Set `STIFF_TOKEN` in the environment, then run
`./build/auth-client https://your-api.example/resource`.
No registry or BendHub is involved. Commit the revision file alongside your app;
upgrades are explicit. See the example README for dependency and token handling.

## Bend API

The complete [example](examples/get-json.bend) sends an HTTPS request, matches
its result, reads the nested JSON `slideshow.title` field and prints it.

```python
def main() -> IO(Unit):
  do IO<Unit>:
    response : Net.JsonResult <- Net.Stiff.send_json(Http.get("https://httpbin.org/json"))
    show(response)
```

`Http` imports `src/http.bend` and `Net` imports `src/io.bend`, with paths relative
to your `.bend` file. The example includes these imports and `show`.

| Operation | Result |
| --- | --- |
| `Http.get(url)` | GET request with default limits |
| `Http.post_json(url, body)` | JSON POST request; body is JSON text |
| `Http.put_json(url, body)` | JSON PUT request |
| `Http.patch_json(url, body)` | JSON PATCH request |
| `Http.delete(url)` | DELETE request without a request body |
| `Http.head(url)` | HEAD request; response body is empty |
| `Http.with_header(name, value, request)` | Set a header; latest call wins, case-insensitively |
| `Http.with_bearer(token, request)` | Set `Authorization: Bearer <token>` |
| `Http.with_timeout(ms, request)` | Request with a whole-transfer deadline |
| `Http.with_max_bytes(bytes, request)` | Request with a response-size limit |
| `Net.Stiff.send(request)` | `HttpOk{Response{status, body, headers}}` or `HttpError{code, message}` |
| `Net.header(name, headers)` | First matching value or `None{}`; use a lowercase name |
| `Net.header_values(name, headers)` | All matching values in wire order |
| `Net.Stiff.send_json(request)` | `JsonOk{status, value}` or `JsonError{code, message}` |
| `Json.Json.parse(text)` | `JsonDone{value}` or `JsonFailure{code, message}` |
| `Json.Json.stringify(value)` | `JsonEncoded{text}` or `JsonEncodeFailure{code, message}` |
| `Json.Json.stringify_with_limit(value, max_bytes)` | Encode with an explicit UTF-8 output-byte limit |
| `Json.field(key, value)` | `Some{value}` or `None{}` |
| `Http.is_success(status)` | Whether status is 200–299 |

`Json` imports `src/json.bend`. Values have explicit `JsonNull`, `JsonBool`,
`JsonNumber`, `JsonString`, `JsonArray` and `JsonObject` constructors. Arrays and
object entries are Bend lists. `Json.as_string` returns an optional String.

## Build JSON responses

`Json.object`, `Json.array`, `Json.string`, `Json.boolean`, `Json.null` and
`Json.u32` build values directly. Objects take a list of `(name, value)` pairs;
arrays take a list of values. For example, in a handler importing `server.bend`
as `Web` and `json.bend` as `Json`:

```python
Web.json_value(200, Json.object([
  ("message", Json.string("Hello \"Bend\"")),
  ("items", Json.array([Json.u32(1), Json.boolean(True{}), Json.null()]))]))
```

`Web.json_value(status, value)` returns `IO(Web.Reply)` with the JSON content
type and correct escaping. An encoding failure becomes a fixed JSON HTTP 500;
use `Json.Json.stringify` directly if you need to handle its error yourself.
`Web.json(status, text)` remains the raw-text helper.

Encoding defaults to a 16 MiB UTF-8 output limit. An explicit limit must be
1–16,777,216 bytes; depth is limited to 128, matching the decoder. Invalid Unicode
scalars, NUL object keys and duplicate object keys are rejected. Existing parse
behavior still resolves duplicate input keys to the last value before encoding.
Object and array builders preserve list order; encoding preserves that order.

`JsonNumber{decimal}` permits signed/fractional/exponent values, but encoding
validates exact JSON number syntax and the decoder's numeric range. It preserves
the supplied valid token; it does not promise arbitrary-precision arithmetic.
Errors include `invalid_json_value`, `invalid_json_limit`, `json_too_large`,
`json_too_deep` and `json_number_range`. String controls (including embedded NUL)
are escaped; valid Unicode is emitted as UTF-8. No partial output is returned.
Serialization is a bounded synchronous native effect, not a pure verified law.

## Update and delete resources

Use `Http.put_json(url, text)`, `Http.patch_json(url, text)` or
`Http.delete(url)` with `Net.Stiff.send` (or `send_json` when a JSON response
is expected). The [methods example](examples/methods.bend) compiles and runs
these helpers with a caller-supplied endpoint.

PUT/PATCH use the same JSON validation, authentication, deadlines and response
limits as POST. Custom content types such as `application/merge-patch+json` can
be set with `Http.with_header`; Stiff does not interpret patch semantics.
GET, HEAD and DELETE reject nonempty request bodies. Only the six exact uppercase
methods are supported, including when using the `Request` constructor directly.

Use `Stiff.send(Http.head(url))` for a status-only check. HEAD returns an empty
body even when the server advertises a nonzero representation length.
`send_json` still requires a JSON response, so use `send` for HEAD and responses
such as HTTP 204. Response headers are available even for HEAD and HTTP error statuses.
Stiff adds no retries for any method; a timeout does not prove that a write failed.

## Build URLs and queries

Import `src/url.bend` as `Url`. `Url.Url.with_query(base, params)` appends
raw name/value pairs to an absolute HTTP(S) URL:

```python
Url.Url.with_query("https://example.com/search?limit=10#results", [
  Url.QueryParam{"q", "Bend & 🌱"},
  Url.QueryParam{"tag", "a"},
  Url.QueryParam{"tag", "b"}])
# UrlReady{"https://example.com/search?limit=10&q=Bend%20%26%20%F0%9F%8C%B1&tag=a&tag=b#results"}
```

Both `with_query` and `Url.Url.encode_component(text)` return
`IO(Url.UrlResult)`: match `UrlReady{text}` or `UrlError{code}`.
Construction performs no network request. The
[query client example](examples/query-client.bend) builds a URL and sends it:

```sh
./scripts/build-native.sh examples/query-client.bend .cache/native/query-client
./.cache/native/query-client https://your-api.example/search 'Bend & 🌱'
```

Components use UTF-8 percent encoding, uppercase hex, and `%20` for spaces.
Only letters, digits and `-._~` remain literal. Reserved delimiters, plus signs,
percent signs and embedded NUL are encoded as data. Inputs are raw text:
already-encoded `%2F` becomes `%252F`. This is not form encoding or a whole-URL
encoder. Encoding `.` or `..` does not prevent path traversal.

Query pairs retain order, repeated names and empty names/values. Existing base
query bytes and fragments are preserved without decoding, sorting or replacing
fields; the HTTP transport may still normalize other URL components.
Base URLs must be ASCII URI text with valid percent escapes and an explicit
lowercase `http://` or `https://` scheme. Credentials, raw spaces, controls,
backslashes and unencoded Unicode are rejected. URL syntax is checked with
libcurl. This does not restrict destinations or provide an SSRF filter.

Each operation has a 65,536-byte output limit; `with_query` also limits base
input to 65,536 bytes and accepts at most 128 pairs. Encoding expansion and the
existing query/fragment count toward the output limit. Failures return no partial
URL and never echo inputs. Codes include `invalid_url`, `invalid_url_text`,
`url_too_large`, `too_many_query_params`, `url_initialization` and
`url_allocation`. These are bounded native effects, not formally verified laws.

## Read response headers

`Net.Response{status, body, headers}` exposes a list of
`Net.ResponseHeader{name, value}`. Names are lowercase; values have leading and
trailing spaces/tabs removed. Duplicate fields remain separate and retain wire
order. For example, use `Net.header("etag", headers)` for the first ETag or
`Net.header_values("set-cookie", headers)` for every cookie without comma-joining.

The [response headers example](examples/response-headers.bend) demonstrates both
helpers and iteration over all fields:

```sh
./scripts/build-native.sh examples/response-headers.bend .cache/native/response-headers
./.cache/native/response-headers https://your-api.example/resource HEAD
```

Only the final response's initial headers are returned. Informational responses,
proxy CONNECT headers and trailers are not exposed; trailers cannot replace
initial metadata. Headers describe the wire response: for example, Content-Length
may differ from the decoded body's size after decompression.

Header handling accepts UTF-8 values, including empty values. Invalid UTF-8,
invalid field names and forbidden controls fail with `invalid_response_header`.
This is a text API; arbitrary non-UTF-8 header bytes are not supported.
Limits are 8 KiB per callback line, 64 KiB total callback bytes including status
and separator lines, and 128 field lines. Totals include informational responses
and trailers (proxy CONNECT headers are suppressed). Exceeding a callback limit returns
`headers_too_large`, with no partial response or echoed field values. libcurl can
reject malformed or oversized protocol data earlier, reported as `network`.
Folded legacy fields follow libcurl's normalization when available; an unnormalized
continuation line is rejected.

**API change:** `Response` now has a third field. Update raw-response patterns
from `Response{status, body}` to `Response{status, body, headers}`.
`send_json` retains its existing status/value result and discards headers.
When JSON and metadata are both needed, call `send`, retain its headers and
parse the body with `Json.Json.parse`. Stiff does not interpret caching,
pagination, cookies or rate-limit policy for the application.

## Behavior

- GET, HEAD, DELETE and JSON POST/PUT/PATCH with custom headers and bearer authentication.
- Default deadline: 10 seconds, covering headers and body.
- Default response limit: 1 MiB after decompression, before UTF-8 decoding.
- HTTP(S) only; embedded URL credentials are rejected.
- TLS certificate and hostname verification stay enabled. `STIFF_CA_BUNDLE`
  selects a PEM CA file without bypassing verification.
- HTTP 3xx, 4xx and 5xx are responses. Redirects are not followed and Stiff adds
  no retry loop. A timeout or interruption cannot undo an external operation.
- Bodies must be valid UTF-8. JSON POST/PUT/PATCH bodies are validated before sending.
- Native SIGINT terminates the process, preventing continuation output. There is
  no per-request cancellation token.
- Failure codes include `invalid_request`, `invalid_header`, `invalid_json_request`, `network`,
  `timeout`, `body_too_large`, `invalid_utf8`, `invalid_json_response`,
  `json_number_range`, `json_too_deep`, `headers_too_large`, and `invalid_response_header`.

Header names must be ASCII HTTP tokens. Values reject NUL, CR/LF and other
control characters except horizontal tabs. Empty values are sent explicitly.
Limits are 128 entries, 8 KiB per name/value, and 64 KiB total including separators;
these apply before duplicate names are resolved. Invalid headers fail before
network access, and errors never include header values.

Stiff owns `Host`, `Content-Length`, `Transfer-Encoding`, `Connection`, `Expect`,
`Trailer`, `Upgrade`, `Proxy-Authorization`, `Proxy-Connection`, `Accept-Encoding`
and `TE`; these cannot be supplied. `Accept` defaults to `application/json` and
JSON POST/PUT/PATCH adds `Content-Type: application/json`; either can be overridden.
`with_bearer` formats a header only: it does not acquire or refresh credentials.
Use HTTPS for real credentials. Custom headers are excluded from proxy CONNECT.

The `Request` constructor now has a sixth field, `headers: List<&2, Header>`.
Prefer the request helpers; direct constructor users must add `Nil{}` for no headers.

Decoded numbers are decimal strings from json-c, without an arbitrary-precision
contract. Integer tokens outside ±9,007,199,254,740,991 are rejected. Duplicate
keys use the last value; object-entry ordering is unspecified. Nesting beyond
128 levels, NUL object keys and unpaired Unicode surrogate escapes are rejected.
Embedded NUL string values and valid Unicode surrogate pairs are supported.

This is a general network client, not an SSRF filter. Applications accepting
untrusted destinations need their own destination policy.

## Verification and limits

`make test` checks the pure laws with the standalone Bend checker, requires a
false proof to fail, and compiles actual executables for local HTTP/HTTPS tests.
The executables are copied outside the checkout and run without source or tools
on PATH. The standalone example is also copied into a separate project, fetches
its Git-pinned dependency and compiler, and calls a local HTTPS API with synthetic
credentials. That integration check requires GitHub network access. CI performs
this native workflow on Linux without JavaScript actions.

The laws cover pure request policy. They do not verify libcurl, json-c, native
memory safety, or the Bend compiler. Compiler layouts are pinned private ABI.
The sanitizer failure was isolated to generated calling conventions on the
inspected macOS toolchain. `make test-sanitize` exercises an explicit standard-C
ABI with ASan/UBSan; normal builds remain unchanged. The original instrumented
ABI is still incompatible. See [sanitizer findings and coverage limits](docs/sanitizers.md).

Contributions should include a runnable example or failing case, preserve the
compiler pin unless deliberately upgrading it, and distinguish pure proofs from
foreign implementation behavior.

## Load and recovery measurements

`make benchmark` runs native loopback workloads and records validated throughput,
latency percentiles, sampled memory, overload rejection, recovery and shutdown.
See [the workload, report format and limits](docs/benchmark.md). A short version
also runs in CI. Passing these checks is not a production-capacity claim.

## License

MIT. Bend is an independent upstream project; its downloaded compiler retains
its own license notices. No upstream source is vendored or relicensed here.
