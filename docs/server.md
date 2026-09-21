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
| `Web.Server.listen(config)` | `Listening{actual_port}` or `ListenError{code}`; default transport limits |
| `Web.Server.listen_with_limits(config, TransportLimits{max_connections, read_timeout_ms})` | Explicit accepted-connection cap and absolute request-read deadline |
| `Web.serve(~handler)` | Receive requests and spawn concurrent handler computations |
| `Web.json_value(status, value)` | Encode a JSON value into `IO(Reply)`; encoding failures become a fixed HTTP 500 |
| `Web.json(status, body)` | JSON content type with the supplied text; does not serialize or validate it |
| `Web.with_header(name, value, reply)` | Latest same-name value wins, ignoring case |
| `Web.header(lowercase_name, headers)` | First matching incoming header value, or `None` |
| `Web.Server.active(id)` | Cooperative checkpoint: false for an expired, closed, finished or unknown request |
| `Web.Server.finish(id)` | Release a manually dispatched handler budget after all its work finishes; idempotent |
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
must keep reading and call `Server.finish(id)` after **all** work for each received
request completes, including reply failures and cancellation. A reply alone does
not release that handler budget. This is a new requirement for manual dispatch;
`serve` handles it automatically. Do not call `finish` early or use detached work
to bypass the budget.

## Limits and shutdown

`Config{address, port, max_body, max_pending, timeout_ms, grace_ms}` defaults to:

- 1 MiB incoming body limit; configurable from 1 byte through 16 MiB.
- 128 pending network requests **and** 128 admitted handlers; configurable together
  from 1 through 128 with `max_pending`. Excess complete requests receive 503.
  Network slots last through reply completion or expiry. Handler budgets last
  until the computation returns and `serve` finishes it, even after network expiry.
  A queued request that expires before `Server.next` claims it releases its budget.
- 16 KiB aggregate incoming headers and at most 128 application-visible headers.
- 256 accepted connections, including incomplete requests and responses still
  being written. At this cap, socket acceptance pauses until capacity is freed.
- A 10-second absolute deadline from socket acceptance until the complete request
  reaches HTTP dispatch. Trickle traffic does not extend this deadline.
- A 10-second libevent I/O inactivity timeout while reading/writing, plus a
  10-second deadline from dispatch through response completion.
- A 5-second shutdown grace period. Timeout/grace settings allow 1–600,000 ms;
  deadline enforcement uses a 10 ms timer.

`Server.listen(config)` uses 256 connections and takes its absolute read deadline
from `Config.timeout_ms`. `Server.listen_with_limits` preserves the six-field
`Config` and accepts `TransportLimits{max_connections, read_timeout_ms}` to set
these separately: 1–1,024 connections and 1–600,000 ms. Zero is invalid.

The connection cap covers sockets accepted by Stiff, not the OS listen backlog.
At capacity, new clients may connect and wait in that backlog; they are not
promised a 503. Their read deadline starts when Stiff accepts them. In contrast,
excess fully read work at the separate pending-request limit receives 503.
Read expiry closes the connection; a 408 response is not guaranteed. These limits
do not provide per-client fairness or network flood protection. A public-facing
proxy still needs its own limits. Timers depend on the event loop being scheduled.

The connection tracker uses libevent's public bufferevent filter/lifetime API.
The output filter retains bytes until the underlying socket queue drains, so
response completion cannot prematurely close a socket. This temporarily stores
an additional copy of queued response bytes; the response size and connection
limits remain distinct from a process-wide memory budget. Allocation/setup
failure in this transport path terminates the process rather than accepting an
untracked connection.
Mixed Transfer-Encoding/Content-Length, repeated framing headers, repeated Host,
invalid UTF-8, non-origin-form targets and URI fragments are rejected before
Bend dispatch. Libevent may reject malformed HTTP earlier.

SIGINT, SIGTERM or `Server.stop()` closes the listener, rejects newly completed
requests and drains already dispatched replies. On the grace deadline, remaining
network requests are closed. Partial undispatched requests are closed when the
server finishes draining. Deadline closure is a connection close, not a promised
HTTP error response. Libevent can discover a disconnected peer only when I/O
resumes; its handler continues to count against the pending limit meanwhile.

## Cooperative cancellation and application budgets

`Server.active(id)` lets a handler check whether its request is still usable.
It becomes false at the request deadline, when libevent observes the connection
close, after response completion, after `finish`, or when the network server stops.
Unknown IDs return false. A normal shutdown lets handlers run during network
grace; remaining requests become inactive when grace expires. A peer reset may
not be detected until libevent resumes I/O, so immediate disconnect cancellation
is not promised. The request deadline remains an independent bound.

Check before each bounded stage and after waits/outbound calls, then return
without starting the next stage when inactive. For example, inside a handler:

```bend
active : Bool <- Web.Server.active(id)
checkpoint(active, u => next_stage())
```

Here `checkpoint` matches the Bool, calls the supplied continuation only for
`True{}`, and returns a reply for `False{}`. The reply may be discarded because
the connection is already closed. The native fixture
[`cooperative`](../test/fixtures/native-server.bend) demonstrates a structurally
bounded loop, 50 ms checkpoints and skipping the final simulated side effect.
`serve` also checks activity before starting a newly received handler.

This is cooperative cancellation. The pinned Bend runtime exposes `IO.spawn`
but no task cancellation handle. A checkpoint cannot preempt pure computation,
interrupt `IO.sleep` or an already-running outbound effect, roll back a side
effect, or atomically guard an external operation against a later disconnect.
Bound individual effects independently, for example with HTTP client timeouts.

Noncooperative handlers retain their budget after their sockets close. This
prevents repeated network timeouts from admitting unbounded concurrent handlers;
it deliberately returns 503 while the application is still occupied. A handler
that never returns permanently consumes its budget. Spawned children are not
tracked independently; join them before returning if they belong to the request.
This is a handler-count budget, not CPU preemption, a byte quota or a process-wide
memory limit. Bend computations can outlive network grace, and the process exits
only after they finish. A strict process-exit deadline needs process isolation.

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
TCP resets, absolute read deadlines for idle/header/body/chunked clients, accepted
connection caps and recovery, large response delivery, 100-continue, invalid
transport limits, retained handler budgets after network expiry, cooperative
cancellation after deadlines/resets/grace, signal/programmatic shutdown and grace expiry.
The standalone client and existing pure-law checks remain in the same suite.

This is experimental. Libevent, native effects and the Bend compiler are trusted
implementation, not formally verified. Combined sanitizers run through an explicit standard-ABI diagnostic profile;
the original ABI incompatibility remains. See [sanitizer notes](sanitizers.md). Native-only
execution and passing integration tests do not establish memory safety.
