# Native HTTP server

Stiff's server uses libevent 2.1.12+ for HTTP parsing and nonblocking network I/O.
Bend owns application routing and handlers. The native effect requires libevent
in addition to the existing build prerequisites. Client-only builds do not link
libevent. There is no JavaScript or Python application runtime.

```sh
make setup
make server
./.cache/native/server 127.0.0.1 8080
```

The example serves `GET /health`, `POST /echo` (parse and re-encode),
`POST /inspect` (construct a response around the parsed value) and `GET /slow`
(a 250 ms asynchronous handler). Other method/path combinations return 404.
It prints the actual bound port, so `127.0.0.1 0` is useful for tests. SIGINT or
SIGTERM initiates shutdown. TLS belongs at a reverse proxy for this first version;
Stiff does not configure or deploy that proxy.

## Bend interface

Import `src/server.bend` as `Web`. A handler has type
`Web.Incoming -> IO(Web.Reply)`. After matching `Web.Listening{port}`, call
`Web.serve(~handler)` to dispatch concurrent Bend computations until shutdown.
The handler template must refer to a top-level definition, as in
[the runnable example](../examples/server.bend). The accept loop is explicitly
`@unsafe`: termination depends on external shutdown, not a pure proof.

| API | Meaning |
| --- | --- |
| `Web.config(address, port)` | Default configuration; address is an IPv4/IPv6 literal |
| `Web.Server.listen(config)` | `Listening{actual_port}` or `ListenError{code}` |
| `Web.serve(~handler)` | Receive requests and spawn concurrent handler computations |
| `Web.json_value(status, value)` | Encode a JSON value into `IO(Reply)`; encoding failures become a fixed HTTP 500 |
| `Web.json(status, body)` | JSON content type with the supplied text; does not serialize or validate it |
| `Web.with_header(name, value, reply)` | Latest same-name value wins, ignoring case |
| `Web.header(lowercase_name, headers)` | First matching incoming header value, or `None` |
| `Web.Server.stop()` | Stop admissions and start the network grace period; idempotent |

`Incoming` contains `id`, `method`, `path`, `target`, `headers`, and `body`.
`path` excludes the query; `target` retains it. Neither is percent-decoded or
normalized. Incoming header names are lowercase; duplicate ordinary headers are
preserved in order. The header list uses `Web.ServerHeader{name, value}`. Bodies
must be UTF-8; compressed request bodies and arbitrary binary bodies are not
provided by this API.

`Reply{status, headers, body}` supplies the response. Status must be 200–599;
204, 205 and 304 require an empty body. Responses are limited to 16 MiB and
headers to 128 entries/16 KiB total, with 8 KiB per name/value. Header names must
be HTTP tokens; values reject control characters except tabs. The transport owns
Content-Length, Transfer-Encoding, Connection and Trailer. Every response closes
its connection. Streaming, keep-alive, WebSockets and HTTP/2 are not implemented.
`serve` converts a rejected handler response into a fixed 500 when the request
is still open; it does not expose the rejected header/body in that error.

For manual dispatch, `Server.next()` returns `Received{Incoming{...}}` or
`Stopped{}`. `Server.reply(id, reply)` returns `Sent{}` when a reply is accepted
for writing, or `ReplyError{code}`; it does not acknowledge delivery to the peer.
A request may be replied to once. Expired/disconnected IDs return `request_closed`.
Codes also include `invalid_response`, `server_stopped` and `server_memory`.
IDs are local handles, not authentication capabilities. A low-level consumer
must keep reading and finish its handlers; `serve` does this for the common case.

## Limits and shutdown

`Config{address, port, max_body, max_pending, timeout_ms, grace_ms}` defaults to:

- 1 MiB incoming body limit; configurable from 1 byte through 16 MiB.
- 128 dispatched/pending requests; configurable from 1 through 128. Excess
  complete requests receive 503. This counts work until reply completion or expiry.
- 16 KiB aggregate incoming headers and at most 128 application-visible headers.
- A 10-second libevent I/O inactivity timeout while reading/writing, plus a
  10-second deadline from dispatch through response completion.
- A 5-second shutdown grace period. Timeout/grace settings allow 1–600,000 ms;
  deadline enforcement uses a 10 ms timer.

These are not a total connection cap or an absolute pre-dispatch read deadline.
Many incomplete or slowly trickling requests can still consume connections;
a public-facing reverse proxy needs its own connection and request-read limits.
Mixed Transfer-Encoding/Content-Length, repeated framing headers, repeated Host,
invalid UTF-8, non-origin-form targets and URI fragments are rejected before
Bend dispatch. Libevent may reject malformed HTTP earlier.

SIGINT, SIGTERM or `Server.stop()` closes the listener, rejects newly completed
requests and drains already dispatched replies. On the grace deadline, remaining
network requests are closed. Partial undispatched requests are closed when the
server finishes draining. Deadline closure is a connection close, not a promised
HTTP error response. Libevent can discover a disconnected peer only when I/O
resumes; its handler continues to count against the pending limit meanwhile.

Bend handlers can outlive the network grace period: stopping the server does not
cancel timers, outbound effects or CPU work, or undo side effects. The Bend
process exits after its remaining computations finish. Applications must bound
those computations independently if they require a process-exit deadline.

One listener lifetime is supported per process. The server owns SIGINT/SIGTERM
handling during that lifetime and restores handlers during cleanup. It cannot
be restarted in-process; a second successful-listen attempt returns
`already_started`. Bind failures return `listen_failed`; invalid configuration
returns `invalid_config`. No service is installed or started by setup/build.

## Verification

`make test` compiles actual server/client executables, removes generated C from
the test directory and runs with an empty executable search path. Tests cover
Stiff-client JSON POST, routing/query separation, request/response headers,
malformed and ambiguous framing, size/UTF-8 checks, concurrency/backpressure,
TCP resets, request deadlines, signal/programmatic shutdown and grace expiry.
The standalone client and existing pure-law checks remain in the same suite.

This is experimental. Libevent, native effects and the Bend compiler are trusted
implementation, not formally verified. Combined sanitizers run through an explicit standard-ABI diagnostic profile;
the original ABI incompatibility remains. See [sanitizer notes](sanitizers.md). Native-only
execution and passing integration tests do not establish memory safety.
