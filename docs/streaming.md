# Response streaming and persistent HTTP

Stiff can send a bounded HTTP/1.1 response in chunks from a manually dispatched
request. This supports finite server-sent event responses and lets an application
opt into reusing that connection for its next request. The existing
`Server.reply` and `Web.serve` behavior is unchanged: ordinary replies send a
bounded body and close the connection.

## Interface

Import `src/server.bend` as `Web`, receive a request with `Web.Server.next()`,
then use these effects in order:

| API | Meaning |
| --- | --- |
| `Web.Server.stream_start(id, StreamHead{status, headers, connection})` | Validate and send the response head |
| `Web.Server.stream_write(id, chunk)` | Queue one text chunk |
| `Web.Server.stream_end(id)` | Finish the chunked response |
| `Web.sse_head(connection)` | A status-200 head with `text/event-stream` and `no-cache` |
| `Web.CloseAfter{}` | Close after the final bytes drain; prefer this unless reuse is useful |
| `Web.KeepAlive{}` | Reuse the connection after the final bytes drain |

Each effect returns `Sent{}` when libevent has accepted the operation or
`ReplyError{code}` when it cannot. Call `Server.finish(id)` after the application
has ended the stream and completed all handler work, just as with other manual
dispatch. A minimal event stream is:

```bend
start : Web.Replied <- Web.Server.stream_start(id, Web.sse_head(Web.CloseAfter{}))
first : Web.Replied <- Web.Server.stream_write(id, "event: ready\ndata: one\n\n")
second : Web.Replied <- Web.Server.stream_write(id, "data: two\n\n")
ended : Web.Replied <- Web.Server.stream_end(id)
Web.Server.finish(id)
```

Applications must inspect every result and stop writing after an error. A start
rejects invalid status or headers, HEAD, and 204, 205 or 304. Writes before a
successful start and repeated start/end operations are rejected. Response
headers retain the ordinary 128-entry, 16 KiB aggregate and 8 KiB field limits.
Content-Length, Transfer-Encoding, Connection and Trailer remain transport-owned.

The aggregate stream body is limited to 16 MiB, matching an ordinary reply.
Chunks are Bend strings and therefore this remains a UTF-8 text API. A stream
uses the request's existing dispatch deadline, handler budget and shutdown grace;
it does not create an unlimited subscription. The maximum configurable request
deadline is ten minutes. `stream_write` returns only after libevent's public
chunk-write completion callback. An overlapping `stream_write` or `stream_end`
for the same request returns `response_write_pending`; this bounds queued response
chunks and preserves the terminal frame. It does not prove that the peer
application consumed the bytes, and an interrupted send cannot be replayed safely.

## Socket lifetime

`KeepAlive` is explicit. Once `stream_end` has been called, libevent's completion
callback waits for Stiff's existing output filter to confirm that the HTTP-facing
queue has drained through the underlying socket. Only then does Stiff arm a fresh
absolute request-read deadline for that connection. This avoids closing after
bytes merely enter an intermediate bufferevent queue and prevents an idle reused
socket from escaping the read deadline.

The next request receives a new request ID and occupies the normal pending and
handler budgets. Persistent connections do not reserve work slots between
requests. Server shutdown closes idle persistent connections and applies the
normal grace period to an active stream. Connection reuse has no per-client
fairness guarantee; public deployments still need proxy-level limits.

Use `CloseAfter` unless the caller benefits from another request on the same
HTTP/1.1 socket. Ordinary `Server.reply` continues to set `Connection: close`,
which preserves existing clients and lifecycle expectations.

## Request streaming

Buffered listeners are unchanged: `Server.listen`, `Server.next` and
`Incoming.body` still expose one validated body after the complete upload.
Applications that need incremental uploads opt into
`Server.listen_streaming_with_limits` (or `Server.listen_streaming`) and receive
metadata through `Server.next_stream`:

```bend
type IncomingHead is Data:
  IncomingHead{id: U32, method: String, path: String, target: String,
    headers: List<&2, ServerHeader>}

type BodyNext is Data:
  BodyChunk{value: String}
  BodyEnd{}
  BodyFailure{code: String}
```

Call `Server.body_next(id)` until `BodyEnd` or `BodyFailure`. A reply is rejected
with `request_body_incomplete` before the terminal body event. Always call
`Server.finish(id)` after the reply attempt. Finishing before a terminal event
cancels the request and closes its connection, so abandoned uploads do not hold
a pending or handler slot until the deadline.

For Content-Length uploads, the Bend-facing pending-body queue is capped at one
64 KiB read window plus a three-byte UTF-8 tail. The transport disables public
bufferevent reads while that chunk waits for the Bend consumer and resumes them
when `body_next` removes it. Libevent can continue parsing bytes already present
in its current read buffer; the explicit queue bound detects that case and fails
the body instead of growing the queue.

For chunk framing, libevent 2.2 invokes its public chunk callback only after one
complete HTTP wire chunk is present. Stiff therefore bounds that read and pending
queue by `Config.max_body`, and delivers the decoded frame before the request's
terminal zero chunk. A sender can choose one wire chunk as large as the complete
allowed body; there is no public libevent callback for delivering a prefix of
that frame. The aggregate decoded body and any one frame retain the same 16 MiB
configuration ceiling. Temporary validation/copy buffers and libevent, filter,
kernel and TCP buffers add bounded memory beyond the Bend-facing queue; this is
not a 64 KiB total-RSS claim.

For a streaming listener, `TransportLimits.max_connections` must not exceed
`Config.max_pending`; this reserves one admission slot for every connection
that can finish its headers. `listen_streaming` derives its connection cap from
`max_pending`. Partial headers remain bounded by the separate connection and
absolute read-deadline controls.

Chunks are valid UTF-8 strings. A code point split across network reads is held
in a tail of at most three bytes and joined to the next read. An invalid
continuation or incomplete final code point produces `BodyFailure{bad_request}`.
Disconnects, read deadlines, handler deadlines and shutdown also unblock a
waiting `body_next` with failure and release transport ownership.

A delivered prefix does not prove that the whole request is valid. Framing,
UTF-8, size, timeout or disconnect failure can follow earlier `BodyChunk`
values. Stage mutations until `BodyEnd`, or apply them in an application
transaction. Stiff cannot roll back effects performed from an earlier chunk.
Buffered `App.json_body` and schema helpers continue to validate complete
bodies; they are not incremental parsers.

The implementation uses the pinned libevent 2.2.2-alpha public
`evhttp_set_newreqcb` hook to install `evhttp_request_set_header_cb` and
`evhttp_request_set_chunked_cb` before parsing starts. The pin includes the
evhttp request-smuggling fixes identified in [GHSA-q39v-w2g7-gr8j](https://github.com/libevent/libevent/security/advisories/GHSA-q39v-w2g7-gr8j).
The upstream chunk callback drains its input on return, which is why Stiff copies
only into its bounded queue and controls subsequent reads at the bufferevent.
The dependency is an alpha until upstream publishes these APIs in a stable
series; its exact source, checksum and local patch are verified by setup.

[`examples/streaming-upload.bend`](../examples/streaming-upload.bend) is a
header-first upload loop that counts chunks without assembling a whole payload,
stops on `BodyFailure`, replies only after `BodyEnd`, and always releases the
handler budget. Build it after setup with:

```sh
scripts/build-native.sh examples/streaming-upload.bend .cache/native/streaming-upload
```

## Boundaries

Transport rejections that reach Stiff use the same JSON shape as `App.error`:
`{"error":{"code":"...","message":"..."}}`, with an appropriate status,
`application/json`, and a closing response. HEAD preserves the status and
headers while omitting the body. Parser-generated syntax, header-limit and body
size errors use libevent's public `evhttp_set_errorcb`. The pinned dependency has
a narrow verified patch that preserves headers set by a successful callback;
upstream 2.2.2-alpha otherwise clears them and forces `text/html` after callback
return. The fallback page remains libevent HTML if Stiff cannot allocate its
error body.

An error rejected before header admission increments `rejected`. A body parser
error after header-first admission increments `admitted`, `rejected`,
`completed` and `failed`: the handler received a request ID, while the transport
ultimately owned the failed response. A streamed UTF-8 failure is likewise
rejected, then counted completed/failed when the application's error reply
finishes.

WebSockets are not included. They need an upgrade-specific connection ownership,
frame, ping/pong, close and backpressure contract; no current Stiff framework use
case requires that larger surface. HTTP/2 is also outside this transport.

The native implementation uses only public libevent APIs:
`evhttp_send_reply_start`, `evhttp_send_reply_chunk_with_cb`,
`evhttp_send_reply_end`, the early request/header/chunk hooks described above,
and public bufferevent filtering and read control. No compiler change or private
libevent structure is used.

`test/test_streaming.py` compiles an actual Bend server and verifies that the
first chunk is observable before its handler produces the second, SSE framing,
reuse of one socket for a second request, the explicit close mode and the
unchanged ordinary-reply default, and rejection beyond the 16 MiB aggregate
body limit. It also verifies that an idle reused connection receives a fresh
absolute read deadline and that transport rejections use the common JSON
envelope, including HEAD framing. Empty writes, overlapping writes and a client
reset while a chunk drain is pending exercise the response-writer lifecycle. Its
upload cases prove header-first delivery for Content-Length and chunk framing
before upload completion, split UTF-8 code points, oversized and malformed bodies,
early disconnect/cancellation, bounded slow consumption and recovery on the next
request. Run it alone with:

```sh
python3 -m unittest discover -s test -p 'test_streaming.py' -v
STIFF_NATIVE_SANITIZE=combined \
  python3 -m unittest discover -s test -p 'test_streaming.py' -v
```
