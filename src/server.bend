import Base
import ./json.bend as Json

type ServerHeader is Data:
  ServerHeader{name: String, value: String}

# One listener lifetime per process. Zero port asks the OS for a free port.
type Config is Data:
  Config{address: String, port: U32, max_body: U32, max_pending: U32, timeout_ms: U32, grace_ms: U32}

def config(address: String, port: U32) -> Config:
  Config{address, port, 1048576, 128, 10000, 5000}

# Accepted socket budget and absolute time to receive the complete request.
type TransportLimits is Data:
  TransportLimits{max_connections: U32, read_timeout_ms: U32}

type Started is Data:
  Listening{port: U32}
  ListenError{code: String}

type Incoming is Data:
  Incoming{id: U32, method: String, path: String, target: String, headers: List<&2, ServerHeader>, body: String}

type Next is Data:
  Received{request: Incoming}
  Stopped{}

# Opt-in upload streaming exposes validated request metadata before the body.
type IncomingHead is Data:
  IncomingHead{id: U32, method: String, path: String, target: String, headers: List<&2, ServerHeader>}

type StreamNext is Data:
  StreamReceived{request: IncomingHead}
  StreamStopped{}

type BodyNext is Data:
  BodyChunk{value: String}
  BodyEnd{}
  BodyFailure{code: String}

type Reply is Data:
  Reply{status: U32, headers: List<&2, ServerHeader>, body: String}

type Replied is Data:
  Sent{}
  ReplyError{code: String}

# Streaming is opt-in. Ordinary Reply keeps its connection-closing behavior.
type ConnectionMode is Data:
  CloseAfter{}
  KeepAlive{}

type StreamHead is Data:
  StreamHead{status: U32, headers: List<&2, ServerHeader>, connection: ConnectionMode}

def json(status: U32, body: String) -> Reply:
  Reply{status, Con{ServerHeader{"Content-Type", "application/json"}, Nil{}}, body}

def encoded_reply(status: U32, result: Json.EncodeResult) -> IO(Reply):
  match result:
    case Json.JsonEncoded{text}:
      IO.pure(Reply, json(status, text))
    case Json.JsonEncodeFailure{code, message}:
      IO.pure(Reply, json(500, "{\"error\":\"JSON encoding failed\"}"))

def json_value(status: U32, value: Json.Json) -> IO(Reply):
  IO.bind(Json.EncodeResult, Reply, Json.Json.stringify(value), encoded_reply(status))

def with_header(name: String, value: String, reply: Reply) -> Reply:
  match reply:
    case Reply{status, headers, body}:
      Reply{status, Con{ServerHeader{name, value}, headers}, body}

# Incoming field names are normalized to lowercase by the native boundary.
def header_step(equal: Bool, value: String, rest: Unit -> Maybe<String>) -> Maybe<String>:
  match equal:
    case True{}: Some{value}
    case False{}: rest(Unit{})

def header(+name: String, headers: List<&2, ServerHeader>) -> Maybe<String>:
  match headers:
    case Nil{}: None{}
    case Con{ServerHeader{key, value}, tail}:
      header_step(String.eq(name, key), value, u => header(name, tail))

def Server.listen(config: Config) -> IO(Started):
  import "./effects/server.c"

def Server.listen_with_limits(config: Config, limits: TransportLimits) -> IO(Started):
  import "./effects/server.c"

# Request streaming is a listener-wide opt-in. Buffered listeners retain their
# existing Incoming/next API and allocation behavior.
def Server.listen_streaming(config: Config) -> IO(Started):
  import "./effects/server.c"

def Server.listen_streaming_with_limits(config: Config, limits: TransportLimits) -> IO(Started):
  import "./effects/server.c"

def Server.next() -> IO(Next):
  import "./effects/server.c"

def Server.next_stream() -> IO(StreamNext):
  import "./effects/server.c"

# Bounded pending text is retained per request while the consumer works.
def Server.body_next(id: U32) -> IO(BodyNext):
  import "./effects/server.c"

def Server.reply(id: U32, reply: Reply) -> IO(Replied):
  import "./effects/server.c"

# Native boundary uses a numeric flag instead of relying on the compiler's
# private representation of a nullary data constructor.
def Server.stream_start_raw(id: U32, status: U32, headers: List<&2, ServerHeader>, keep_alive: U32) -> IO(Replied):
  import "./effects/server.c"

def stream_start_mode(id: U32, status: U32, headers: List<&2, ServerHeader>, connection: ConnectionMode) -> IO(Replied):
  match connection:
    case CloseAfter{}: Server.stream_start_raw(id, status, headers, 0)
    case KeepAlive{}: Server.stream_start_raw(id, status, headers, 1)

# Begin one bounded chunked response. Statuses that forbid bodies are rejected.
def Server.stream_start(id: U32, head: StreamHead) -> IO(Replied):
  match head:
    case StreamHead{status, headers, connection}: stream_start_mode(id, status, headers, connection)

# The aggregate body across writes is limited to 16 MiB.
def Server.stream_write(id: U32, chunk: String) -> IO(Replied):
  import "./effects/server.c"

def Server.stream_end(id: U32) -> IO(Replied):
  import "./effects/server.c"

def sse_head(connection: ConnectionMode) -> StreamHead:
  StreamHead{200, [
    ServerHeader{"Content-Type", "text/event-stream"},
    ServerHeader{"Cache-Control", "no-cache"}], connection}

# Cooperative checkpoint; does not preempt work or undo effects.
def Server.active(id: U32) -> IO(Bool):
  import "./effects/server.c"

# Manual dispatch must release its handler budget after all work finishes.
def Server.finish(id: U32) -> IO(Unit):
  import "./effects/server.c"

def Server.stop() -> IO(Unit):
  import "./effects/server.c"

def finish_reply(id: U32, result: Replied) -> IO(Unit):
  match result:
    case Sent{}:
      IO.pure(Unit, Unit{})
    case ReplyError{code}:
      do IO<Unit>:
        ignored : Replied <- Server.reply(id, json(500, "{\"error\":\"response rejected\"}"))
        IO.pure(Unit, Unit{})

def dispatch_live(handler: Incoming -> IO(Reply), request: Incoming) -> IO(Unit):
  match request:
    case Incoming{+id, method, path, target, headers, body}:
      do IO<Unit>:
        reply : Reply <- handler(Incoming{id, method, path, target, headers, body})
        result : Replied <- Server.reply(id, reply)
        finish_reply(id, result)
        Server.finish(id)

def discard_request(request: Incoming) -> IO(Unit):
  match request:
    case Incoming{id, method, path, target, headers, body}: Server.finish(id)

def dispatch_active(active: Bool, handler: Incoming -> IO(Reply), request: Incoming) -> IO(Unit):
  match active:
    case True{}: dispatch_live(handler, request)
    case False{}: discard_request(request)

def dispatch(handler: Incoming -> IO(Reply), request: Incoming) -> IO(Unit):
  match request:
    case Incoming{+id, method, path, target, headers, body}:
      IO.bind(Bool, Unit, Server.active(id), active =>
        dispatch_active(active, handler, Incoming{id, method, path, target, headers, body}))

def serve_next(handler: Incoming -> IO(Reply), rest: Unit -> IO(Unit), next: Next) -> IO(Unit):
  match next:
    case Received{request}:
      do IO<Unit>:
        IO.spawn(Unit, dispatch(handler, request))
        rest(Unit{})
    case Stopped{}:
      IO.pure(Unit, Unit{})

# The accept loop ends on external shutdown, not a pure termination proof.
@unsafe
def serve(~handler: Incoming -> IO(Reply)) -> IO(Unit):
  IO.bind(Next, Unit, Server.next(), serve_next(handler, u => serve(~handler)))

# Process/listener lifetime counters and current bounded gauges. No reset API.
type Metrics is Data:
  Metrics{admitted: U32, completed: U32, failed: U32, rejected: U32, expired: U32, read_expired: U32, disconnected: U32, connections: U32, pending: U32, handlers: U32}

def Server.metrics() -> IO(Metrics):
  import "./effects/server.c"

def metrics_json(metrics: Metrics) -> Json.Json:
  match metrics:
    case Metrics{admitted, completed, failed, rejected, expired, read_expired, disconnected, connections, pending, handlers}:
      Json.object([
        ("admitted", Json.u32(admitted)), ("completed", Json.u32(completed)),
        ("failed", Json.u32(failed)), ("rejected", Json.u32(rejected)),
        ("expired", Json.u32(expired)), ("read_expired", Json.u32(read_expired)),
        ("disconnected", Json.u32(disconnected)), ("connections", Json.u32(connections)),
        ("pending", Json.u32(pending)), ("handlers", Json.u32(handlers))])
