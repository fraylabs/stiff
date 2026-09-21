import Base
import ../src/app.bend as App
import ../src/router.bend as Router
import ../src/schema.bend as Schema
import ../src/server.bend as Web
import ../src/json.bend as Json
import ../src/store.bend as Db

# Local single-workspace demonstration. Bind only to loopback; no implicit auth.
def schema() -> Schema.Schema:
  Schema.Object{[
    Schema.Field{"operation_id", True{}, Schema.Text{1n, 64n}},
    Schema.Field{"expected_version", True{}, Schema.UInt{0, 4294967295}},
    Schema.Field{"note", True{}, Schema.Object{[
      Schema.Field{"title", True{}, Schema.Text{1n, 80n}},
      Schema.Field{"done", True{}, Schema.Boolean{}},
      Schema.Field{"tags", False{}, Schema.Sequence{Schema.Text{1n, 24n}, 0n, 8n}}
    ], True{}}}
  ], True{}}

def text(value: Maybe<Json.Json>) -> String:
  match value:
    case Some{Json.JsonString{s}}: s
    case other: ""

def number(value: Maybe<&2, U32>) -> U32:
  match value:
    case Some{n}: n
    case None{}: 0

def expected(value: Maybe<Json.Json>) -> U32:
  match value:
    case Some{Json.JsonNumber{s}}: number(U32.read(s))
    case other: 0

def value_or_null(value: Maybe<Json.Json>) -> Json.Json:
  match value:
    case Some{v}: v
    case None{}: Json.null()

def applied(version: U32, replayed: Bool) -> IO(Web.Reply):
  Web.json_value(200, Json.object([("version", Json.u32(version)), ("replayed", Json.boolean(replayed))]))

def conflict(version: U32) -> IO(Web.Reply):
  Web.json_value(409, Json.object([("error", Json.object([
    ("code", Json.string("version_conflict")), ("message", Json.string("Expected version does not match")),
    ("current_version", Json.u32(version))]))]))

def written(result: Db.WriteResult) -> IO(Web.Reply):
  match result:
    case Db.StoreApplied{version}: applied(version, False{})
    case Db.StoreReplayed{version}: applied(version, True{})
    case Db.StoreVersionConflict{version, value}: conflict(version)
    case Db.StoreReplayedVersionConflict{version, value}: conflict(version)
    case Db.StoreMissingConflict{}: App.error(409, "missing_conflict", "Expected note does not exist")
    case Db.StoreReplayedMissingConflict{}: App.error(409, "missing_conflict", "Expected note does not exist")
    case Db.StoreIdempotencyConflict{}: App.error(409, "idempotency_conflict", "Operation ID has different input")
    case Db.StoreWriteError{code, message}: App.error(503, code, message)

def encoded(store: Db.Store, key: String, operation: String, version: U32, result: Json.EncodeResult) -> IO(Web.Reply):
  match result:
    case Json.JsonEncoded{body}:
      IO.bind(Db.WriteResult, Web.Reply, Db.Store.compare_write(store, operation, key, version, body), written)
    case Json.JsonEncodeFailure{code, message}: App.error(422, code, message)

def save(store: Db.Store, key: String, +value: Json.Json) -> IO(Web.Reply):
  IO.bind(Json.EncodeResult, Web.Reply,
    Json.Json.stringify(value_or_null(Json.field("note", value))),
    result => encoded(store, key, text(Json.field("operation_id", value)), expected(Json.field("expected_version", value)), result))

def validated(store: Db.Store, key: String, value: Json.Json) -> IO(Web.Reply):
  Schema.apply(schema(), value, v => save(store, key, v))

def parsed_note(version: U32, result: Json.ParseResult) -> IO(Web.Reply):
  match result:
    case Json.JsonDone{value}: Web.json_value(200, Json.object([("version", Json.u32(version)), ("note", value)]))
    case Json.JsonFailure{code, message}: App.error(500, "stored_value_invalid", "Stored note is invalid")

def found(result: Db.ReadResult) -> IO(Web.Reply):
  match result:
    case Db.StoreFound{version, body}: IO.bind(Json.ParseResult, Web.Reply, Json.Json.parse(body), r => parsed_note(version, r))
    case Db.StoreMissing{}: App.error(404, "not_found", "Note does not exist")
    case Db.StoreReadError{code, message}: App.error(503, code, message)

def operation_result(state: String, key: String, version: U32) -> IO(Web.Reply):
  Web.json_value(200, Json.object([("state", Json.string(state)), ("key", Json.string(key)), ("version", Json.u32(version))]))

def reconciled(result: Db.OperationResult) -> IO(Web.Reply):
  match result:
    case Db.StoreOperationApplied{key, version}: operation_result("applied", key, version)
    case Db.StoreOperationVersionConflict{key, version}: operation_result("version_conflict", key, version)
    case Db.StoreOperationMissingConflict{key}: operation_result("missing_conflict", key, 0)
    case Db.StoreOperationUnknown{}: App.error(404, "operation_unknown", "No committed receipt")
    case Db.StoreOperationError{code, message}: App.error(503, code, message)

def with_id(value: Maybe<String>, next: String -> IO(Web.Reply)) -> IO(Web.Reply):
  match value:
    case Some{+id}: Schema.apply(Schema.Text{1n, 64n}, Json.string(id), v => next(id))
    case None{}: App.error(500, "route_error", "Missing route parameter")

def read(store: Db.Store, params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  with_id(Router.param("id", params), id => IO.bind(Db.ReadResult, Web.Reply, Db.Store.read(store, id), found))

def write(store: Db.Store, params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, path, target, headers, body}:
      with_id(Router.param("id", params), key => App.json_body(body, v => validated(store, key, v)))

def operation(store: Db.Store, params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  with_id(Router.param("id", params), id => IO.bind(Db.OperationResult, Web.Reply, Db.Store.operation(store, id), reconciled))

def health(params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  Web.json_value(200, Json.object([("status", Json.string("ok"))]))

def metrics(params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  do IO<Web.Reply>:
    snapshot : Web.Metrics <- Web.Server.metrics()
    Web.json_value(200, Web.metrics_json(snapshot))

def handler(+store: Db.Store, request: Web.Incoming) -> IO(Web.Reply):
  App.observe(r => Router.route([
    Router.Route{"GET", "/health", health},
    Router.Route{"GET", "/metrics", metrics},
    Router.Route{"GET", "/notes/:id", params => request => read(store, params, request)},
    Router.Route{"PUT", "/notes/:id", params => request => write(store, params, request)},
    Router.Route{"GET", "/operations/:id", params => request => operation(store, params, request)}
  ], r), request)

# Keep the runtime store explicit; Web.serve's handler is a closed template.
@unsafe
def serve(+store: Db.Store) -> IO(Unit):
  IO.bind(Web.Next, Unit, Web.Server.next(),
    Web.serve_next(request => handler(store, request), u => serve(store)))

def listening(store: Db.Store, result: Web.Started) -> IO(Unit):
  match result:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        serve(store)
    case Web.ListenError{code}: IO.die(Unit, 1, code)

def opened(port: U32, result: Db.OpenResult) -> IO(Unit):
  match result:
    case Db.StoreReady{store}:
      IO.bind(Web.Started, Unit, Web.Server.listen(Web.config("127.0.0.1", port)), r => listening(store, r))
    case Db.StoreOpenError{code, message}: IO.die(Unit, 1, code)

def start(args: List<String>) -> IO(Unit):
  match args:
    case Con{path, Con{port, Nil{}}}:
      start_port(path, U32.read(port))
    case other: IO.die(Unit, 2, "usage: notes DATABASE PORT")

def start_port(path: String, port: Maybe<&2, U32>) -> IO(Unit):
  match port:
    case Some{n}: IO.bind(Db.OpenResult, Unit, Db.Store.open(path), r => opened(n, r))
    case None{}: IO.die(Unit, 2, "Invalid port")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    start(args)
