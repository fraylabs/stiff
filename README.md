# Stiff

HTTP building blocks for **Bend 2**. An early, Node-hosted experiment by Fray.

Stiff pairs pure Bend request definitions and response policy with Node's HTTP(S)
transport and JSON parser. The first slice supports GET and JSON POST, deadlines,
cancellation, bounded response bodies, and explicit HTTP status handling.

**Status:** experimental source prototype, pinned to Bend **2.0.20**. This is not
yet a standalone Bend IO library, native backend, web framework, or npm release.

## Run it

Requires Node **26+**, Git, and OpenSSL for the local TLS tests.

```sh
git clone https://github.com/fraylabs/stiff.git
cd stiff
npm run setup
npm test
npm run example -- https://httpbin.org/json
```

Setup fetches the upstream Bend source into ignored `.cache/bend/` and checks its
exact commit, `a5269a6b2c5ccd6752b66df4bc6f60678b4f49bc`. It changes no global tools
and installs no npm dependencies. The source loader is required because this
Bend release does not package it with the standalone binary. Node may print
warnings about upstream module loading; that integration remains experimental.

## Use the prototype

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

These proofs do **not** verify TLS, Node fetch, JSON parsing, the loader, or the
Bend compiler. The host adapter and compiler remain trusted dependencies.

## Direction

The next design question is how a Bend program should perform asynchronous HTTP
effects without depending on a JavaScript entry point. That needs a deliberate
effect API and backend compatibility work. The current prototype establishes a
testable transport contract before committing to native bindings or a framework.

Contributions should include a runnable example or a failing case, clearly
separate pure laws from host behavior, and keep compiler upgrades explicit.

## License

Stiff is MIT licensed. Bend is an independent upstream project; setup retrieves
its source with its own license notices intact. No upstream source is vendored
or relicensed in this repository.
