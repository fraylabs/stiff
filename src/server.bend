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

type Reply is Data:
  Reply{status: U32, headers: List<&2, ServerHeader>, body: String}

type Replied is Data:
  Sent{}
  ReplyError{code: String}

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

def Server.next() -> IO(Next):
  import "./effects/server.c"

def Server.reply(id: U32, reply: Reply) -> IO(Replied):
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

def dispatch(handler: Incoming -> IO(Reply), request: Incoming) -> IO(Unit):
  match request:
    case Incoming{+id, method, path, target, headers, body}:
      do IO<Unit>:
        reply : Reply <- handler(Incoming{id, method, path, target, headers, body})
        result : Replied <- Server.reply(id, reply)
        finish_reply(id, result)

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
