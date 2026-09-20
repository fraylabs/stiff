# Stiff

Native HTTP(S) and JSON building blocks for **Bend 2**. Write a Bend `IO`
program, compile it to an executable, and run it with libcurl and json-c.

**Status:** experimental, pinned to Bend **2.0.20**. No Node or npm dependency.
This is not a static binary distribution or a production-readiness claim.

## Get started

You need Clang, make, pkg-config, libcurl development files (7.85 or newer),
json-c development files, and OpenSSL for tests. Python **3.11.8+** is used only
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
| `Http.with_header(name, value, request)` | Set a header; latest call wins, case-insensitively |
| `Http.with_bearer(token, request)` | Set `Authorization: Bearer <token>` |
| `Http.with_timeout(ms, request)` | Request with a whole-transfer deadline |
| `Http.with_max_bytes(bytes, request)` | Request with a response-size limit |
| `Net.Stiff.send(request)` | `HttpOk{Response{status, body}}` or `HttpError{code, message}` |
| `Net.Stiff.send_json(request)` | `JsonOk{status, value}` or `JsonError{code, message}` |
| `Json.Json.parse(text)` | `JsonDone{value}` or `JsonFailure{code, message}` |
| `Json.field(key, value)` | `Some{value}` or `None{}` |
| `Http.is_success(status)` | Whether status is 200–299 |

`Json` imports `src/json.bend`. Values have explicit `JsonNull`, `JsonBool`,
`JsonNumber`, `JsonString`, `JsonArray` and `JsonObject` constructors. Arrays and
object entries are Bend lists. `Json.as_string` returns an optional String.

## Behavior

- GET and JSON POST with custom headers and bearer authentication.
- Default deadline: 10 seconds, covering headers and body.
- Default response limit: 1 MiB after decompression, before UTF-8 decoding.
- HTTP(S) only; embedded URL credentials are rejected.
- TLS certificate and hostname verification stay enabled. `STIFF_CA_BUNDLE`
  selects a PEM CA file without bypassing verification.
- HTTP 3xx, 4xx and 5xx are responses. Redirects are not followed and Stiff adds
  no retry loop. A timeout or interruption cannot undo an external operation.
- Bodies must be valid UTF-8. JSON POST bodies are validated before sending.
- Native SIGINT terminates the process, preventing continuation output. There is
  no per-request cancellation token.
- Failure codes include `invalid_request`, `invalid_header`, `invalid_json_request`, `network`,
  `timeout`, `body_too_large`, `invalid_utf8`, `invalid_json_response`,
  `json_number_range`, and `json_too_deep`.

Header names must be ASCII HTTP tokens. Values reject NUL, CR/LF and other
control characters except horizontal tabs. Empty values are sent explicitly.
Limits are 128 entries, 8 KiB per name/value, and 64 KiB total including separators;
these apply before duplicate names are resolved. Invalid headers fail before
network access, and errors never include header values.

Stiff owns `Host`, `Content-Length`, `Transfer-Encoding`, `Connection`, `Expect`,
`Trailer`, `Upgrade`, `Proxy-Authorization`, `Proxy-Connection`, `Accept-Encoding`
and `TE`; these cannot be supplied. `Accept` defaults to `application/json` and
JSON POST adds `Content-Type: application/json`; either can be overridden.
`with_bearer` formats a header only: it does not acquire or refresh credentials.
Use HTTPS for real credentials. Custom headers are excluded from proxy CONNECT.

The `Request` constructor now has a sixth field, `headers: List<&2, Header>`.
Prefer the request helpers; direct constructor users must add `Nil{}` for no headers.

Numbers are decimal strings from json-c, without an arbitrary-precision
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
on PATH. CI performs this native workflow on Linux without JavaScript actions.

The laws cover pure request policy. They do not verify libcurl, json-c, native
memory safety, or the Bend compiler. Compiler layouts are pinned private ABI.
A sanitizer failure also reproduces in a Base-only Bend program with no Stiff
imports; it remains unresolved. See [native verification notes](docs/native.md).

Contributions should include a runnable example or failing case, preserve the
compiler pin unless deliberately upgrading it, and distinguish pure proofs from
foreign implementation behavior.

## License

MIT. Bend is an independent upstream project; its downloaded compiler retains
its own license notices. No upstream source is vendored or relicensed here.
