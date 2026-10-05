import Base
import ../../src/app.bend as App
import ../../src/router.bend as Router
import ../../src/schema.bend as Schema
import ../../src/server.bend as Web
import ../../src/json.bend as Json
import ../../src/store.bend as Db
import ./engine.bend as E
import ./spec.bend as S
import ./http.bend as H
import ../../src/contracts.bend as C

# Adapters decode, validate, invoke E.transfer and commit its complete state.
# All balance arithmetic belongs to E. No account is written separately.
def request_schema() -> Schema.Schema:
  Schema.Object{[
    Schema.Field{"idempotency_key", True{}, Schema.UInt{1, 1000000}},
    Schema.Field{"expected_version", True{}, Schema.UInt{1, 4294967294}},
    Schema.Field{"from", True{}, Schema.Text{3n, 5n}},
    Schema.Field{"to", True{}, Schema.Text{3n, 5n}},
    Schema.Field{"amount", True{}, Schema.UInt{1, 200}}
  ], True{}}

def storage_schema() -> Schema.Schema:
  Schema.Object{[
    Schema.Field{"alice", True{}, Schema.UInt{0, 200}},
    Schema.Field{"bob", True{}, Schema.UInt{0, 200}},
    Schema.Field{"receipts", True{}, Schema.Sequence{request_schema(), 0n, 1000n}}
  ], True{}}

def text(value: Maybe<Json.Json>) -> String:
  match value:
    case Some{Json.JsonString{s}}: s
    case other: ""

def number(value: Maybe<&2, U32>) -> U32:
  match value:
    case Some{n}: n
    case None{}: 0

def uint(value: Maybe<Json.Json>) -> U32:
  match value:
    case Some{Json.JsonNumber{s}}: number(U32.read(s))
    case other: 0

# SQLite compares receipt inputs byte-for-byte. Normalize validated fields before
# either concurrent writer constructs its snapshot, not only on the replay path.
def canonical_request(+value: Json.Json) -> Json.Json:
  Json.object([
    ("idempotency_key", Json.u32(uint(Json.field("idempotency_key", value)))),
    ("expected_version", Json.u32(uint(Json.field("expected_version", value)))),
    ("from", Json.string(text(Json.field("from", value)))),
    ("to", Json.string(text(Json.field("to", value)))),
    ("amount", Json.u32(uint(Json.field("amount", value))))])

def entries(value: Maybe<Json.Json>) -> List<&2, Json.Json>:
  match value:
    case Some{Json.JsonArray{items}}: items
    case other: Nil{}

def key(+request: Json.Json) -> Nat:
  U32.to_nat(uint(Json.field("idempotency_key", request)))

def keys(receipts: List<&2, Json.Json>) -> List<&2, Nat>:
  match receipts:
    case Nil{}: Nil{}
    case head <> tail: key(head) <> keys(tail)

def decode(+value: Json.Json) -> E.State:
  E.State{U32.to_nat(uint(Json.field("alice", value))),
    U32.to_nat(uint(Json.field("bob", value))), keys(entries(Json.field("receipts", value)))}

def snapshot(state: E.State, receipts: List<&2, Json.Json>) -> Json.Json:
  match state:
    case E.State{alice, bob, seen}:
      Json.object([("alice", Json.u32(U32.from_nat(alice))),
        ("bob", Json.u32(U32.from_nat(bob))), ("receipts", Json.array(receipts))])

def balances(version: U32, replayed: Bool, state: E.State) -> IO(Web.Reply):
  match state:
    case E.State{alice, bob, seen}:
      Web.json_value(200, Json.object([("version", Json.u32(version)),
        ("replayed", Json.boolean(replayed)),
        ("accounts", Json.object([("alice", Json.u32(U32.from_nat(alice))),
          ("bob", Json.u32(U32.from_nat(bob)))]))]))

# These conversions are the explicit, tested edge of the pure HTTP model.
def domain(+request: Json.Json, direction: E.Direction) -> H.Operation:
  H.Operation{key(request), U32.to_nat(uint(Json.field("expected_version", request))),
    direction, U32.to_nat(uint(Json.field("amount", request)))}

def operation_json(operation: H.Operation) -> Json.Json:
  match operation:
    case H.Operation{key, expected, direction, amount}:
      match direction:
        case E.AliceToBob{}:
          Json.object([("idempotency_key", Json.u32(U32.from_nat(key))), ("expected_version", Json.u32(U32.from_nat(expected))),
            ("from", Json.string("alice")), ("to", Json.string("bob")), ("amount", Json.u32(U32.from_nat(amount)))])
        case E.BobToAlice{}:
          Json.object([("idempotency_key", Json.u32(U32.from_nat(key))), ("expected_version", Json.u32(U32.from_nat(expected))),
            ("from", Json.string("bob")), ("to", Json.string("alice")), ("amount", Json.u32(U32.from_nat(amount)))])

def original_from(from: String, request: Json.Json) -> H.Operation:
  match from:
    case "alice": domain(request, E.AliceToBob{})
    case other: domain(request, E.BobToAlice{})

def original_domain(+request: Json.Json) -> H.Operation:
  original_from(text(Json.field("from", request)), request)

def transfer_balances(status: Nat, version: U32, replayed: Bool, operation: H.Operation, state: E.State) -> IO(Web.Reply):
  match state:
    case E.State{alice, bob, seen}:
      Web.json_value(U32.from_nat(status), Json.object([("version", Json.u32(version)),
        ("replayed", Json.boolean(replayed)), ("operation", operation_json(operation)),
        ("accounts", Json.object([("alice", Json.u32(U32.from_nat(alice))), ("bob", Json.u32(U32.from_nat(bob)))]))]))

def transfer_reply(version: U32, decision: C.Decision<E.State, H.Body>) -> IO(Web.Reply):
  match decision:
    case C.Decision{state, C.Reply{status, H.Applied{operation}}}: transfer_balances(status, version, False{}, operation, state)
    case C.Decision{state, C.Reply{status, H.Replayed{operation}}}: transfer_balances(status, version, True{}, operation, state)
    case C.Decision{state, C.Reply{status, H.Rejected{}}}: App.error(U32.from_nat(status), "insufficient_funds", "Transfer exceeds source balance")
    case C.Decision{state, C.Error{status, code, allow}}: App.error(U32.from_nat(status), code, "Request rejected")

def receipt_hit(hit: Bool, head: Json.Json, rest: Maybe<Json.Json>) -> Maybe<Json.Json>:
  match hit:
    case True{}: Some{head}
    case False{}: rest

def receipt(receipts: List<&2, Json.Json>, +id: Nat) -> Maybe<Json.Json>:
  match receipts:
    case Nil{}: None{}
    case +head <> tail: receipt_hit(Nat.is_eq(key(head), id), head, receipt(tail, id))

def same_request(+a: Json.Json, +b: Json.Json) -> Bool:
  Bool.and(U32.is_eq(uint(Json.field("idempotency_key", a)), uint(Json.field("idempotency_key", b))),
    Bool.and(U32.is_eq(uint(Json.field("expected_version", a)), uint(Json.field("expected_version", b))),
      Bool.and(String.eq(text(Json.field("from", a)), text(Json.field("from", b))),
        Bool.and(String.eq(text(Json.field("to", a)), text(Json.field("to", b))),
          U32.is_eq(uint(Json.field("amount", a)), uint(Json.field("amount", b)))))))

def replay_same(same: Bool, version: U32, state: E.State, original: H.Operation) -> IO(Web.Reply):
  match same:
    case True{}: transfer_reply(version, H.complete(E.Outcome{E.Replayed{}, state}, original))
    case False{}: App.error(409, "idempotency_conflict", "Key already names another request")

def replay(previous: Maybe<Json.Json>, request: Json.Json, version: U32, state: E.State) -> IO(Web.Reply):
  match previous:
    case Some{+original}:
      replay_same(same_request(original, request), version, state, original_domain(original))
    case None{}: App.error(500, "stored_value_invalid", "Missing engine receipt")

def written(+state: E.State, +operation: H.Operation, result: Db.WriteResult) -> IO(Web.Reply):
  match result:
    case Db.StoreApplied{version}: transfer_reply(version, H.complete(E.Outcome{E.Applied{}, state}, operation))
    case Db.StoreReplayed{version}: transfer_reply(version, H.complete(E.Outcome{E.Replayed{}, state}, operation))
    case Db.StoreVersionConflict{version, value}: App.error(409, "version_conflict", "Read accounts and submit a new operation")
    case Db.StoreReplayedVersionConflict{version, value}: App.error(409, "version_conflict", "Read accounts and submit a new operation")
    case Db.StoreMissingConflict{}: App.error(409, "missing_conflict", "Ledger is missing")
    case Db.StoreReplayedMissingConflict{}: App.error(409, "missing_conflict", "Ledger is missing")
    case Db.StoreIdempotencyConflict{}: App.error(409, "idempotency_conflict", "Key already names another transaction")
    case Db.StoreWriteError{code, message}: App.error(503, code, message)

def encoded(store: Db.Store, operation: String, expected: U32, +state: E.State, operation_data: H.Operation, result: Json.EncodeResult) -> IO(Web.Reply):
  match result:
    case Json.JsonEncoded{body}:
      IO.bind(Db.WriteResult, Web.Reply, Db.Store.compare_write(store, operation, "ledger", expected, body), r => written(state, operation_data, r))
    case Json.JsonEncodeFailure{code, message}: App.error(500, code, message)

def save_room(room: Bool, store: Db.Store, +stored: Json.Json, +request: Json.Json, +next: E.State) -> IO(Web.Reply):
  match room:
    case False{}: App.error(409, "ledger_full", "Demo receipt limit reached")
    case True{}:
      IO.bind(Json.EncodeResult, Web.Reply,
        Json.Json.stringify(snapshot(next, request <> entries(Json.field("receipts", stored)))),
        r => encoded(store, "transfer:" ++ Nat.show(key(request)), uint(Json.field("expected_version", request)), next, original_domain(request), r))

def decided(outcome: C.Decision<E.State, H.Body>, store: Db.Store, version: U32, +stored: Json.Json, +request: Json.Json) -> IO(Web.Reply):
  match outcome:
    case C.Decision{next, C.Reply{status, H.Rejected{}}}: App.error(U32.from_nat(status), "insufficient_funds", "Transfer exceeds source balance")
    case C.Decision{next, C.Reply{status, H.Replayed{operation}}}:
      replay(receipt(entries(Json.field("receipts", stored)), key(request)), request, version, next)
    case C.Decision{+next, C.Reply{status, H.Applied{operation}}}:
      save_room(Nat.is_lt(List.length(&2, Json.Json, entries(Json.field("receipts", stored))), 1000n), store, stored, request, next)

    case C.Decision{next, C.Error{status, code, allow}}: App.error(U32.from_nat(status), code, "Request rejected")

def transfer_from(from: String, to: String, store: Db.Store, version: U32, +stored: Json.Json, +request: Json.Json) -> IO(Web.Reply):
  match from to:
    case "alice" "bob":
      decided(H.transfer(decode(stored), domain(request, E.AliceToBob{})), store, version, stored, request)
    case "bob" "alice":
      decided(H.transfer(decode(stored), domain(request, E.BobToAlice{})), store, version, stored, request)
    case other other2: App.error(422, "invalid_accounts", "Use distinct alice and bob accounts")

def supply_valid(valid: Bool, store: Db.Store, version: U32, +stored: Json.Json, request: Maybe<Json.Json>) -> IO(Web.Reply):
  match valid:
    case False{}: App.error(500, "stored_value_invalid", "Ledger total does not match initial supply")
    case True{}:
      match request:
        case None{}: balances(version, False{}, decode(stored))
        case Some{+input}:
          transfer_from(text(Json.field("from", input)), text(Json.field("to", input)), store, version, stored, input)

def valid_stored(verdict: Schema.Verdict, store: Db.Store, version: U32, +stored: Json.Json, request: Maybe<Json.Json>) -> IO(Web.Reply):
  match verdict:
    case Schema.Invalid{path, code}: App.error(500, "stored_value_invalid", "Ledger snapshot does not match schema")
    case Schema.Valid{}:
      supply_valid(Nat.is_eq(S.total(decode(stored)), 200n), store, version, stored, request)

def parsed(store: Db.Store, version: U32, request: Maybe<Json.Json>, result: Json.ParseResult) -> IO(Web.Reply):
  match result:
    case Json.JsonFailure{code, message}: App.error(500, "stored_value_invalid", "Ledger snapshot is invalid JSON")
    case Json.JsonDone{+stored}:
      valid_stored(Schema.validate(storage_schema(), stored), store, version, stored, request)

def found(store: Db.Store, request: Maybe<Json.Json>, result: Db.ReadResult) -> IO(Web.Reply):
  match result:
    case Db.StoreFound{version, body}:
      IO.bind(Json.ParseResult, Web.Reply, Json.Json.parse(body), r => parsed(store, version, request, r))
    case Db.StoreMissing{}: App.error(503, "ledger_missing", "Ledger is not initialized")
    case Db.StoreReadError{code, message}: App.error(503, code, message)

def load(+store: Db.Store, request: Maybe<Json.Json>) -> IO(Web.Reply):
  IO.bind(Db.ReadResult, Web.Reply, Db.Store.read(store, "ledger"), r => found(store, request, r))

def accounts(store: Db.Store, params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  load(store, None{})

def transfer(store: Db.Store, params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, path, target, headers, body}:
      App.json_body(body, value => Schema.apply(request_schema(), value, v => load(store, Some{canonical_request(v)})))

def reconciled(result: Db.OperationResult) -> IO(Web.Reply):
  match result:
    case Db.StoreOperationApplied{key, version}:
      Web.json_value(200, Json.object([("state", Json.string("applied")), ("version", Json.u32(version))]))
    case Db.StoreOperationVersionConflict{key, version}: App.error(409, "version_conflict", "Operation was rejected by version comparison")
    case Db.StoreOperationMissingConflict{key}: App.error(409, "missing_conflict", "Ledger was missing")
    case Db.StoreOperationUnknown{}: App.error(404, "operation_unknown", "No committed SQLite receipt")
    case Db.StoreOperationError{code, message}: App.error(503, code, message)

def operation_number(value: Maybe<&2, U32>, store: Db.Store) -> IO(Web.Reply):
  match value:
    case Some{n}:
      IO.bind(Db.OperationResult, Web.Reply, Db.Store.operation(store, "transfer:" ++ U32.show(n)), reconciled)
    case None{}: App.error(422, "invalid_key", "Use a numeric idempotency key")

def operation_id(value: Maybe<String>, store: Db.Store) -> IO(Web.Reply):
  match value:
    case Some{id}: operation_number(U32.read(id), store)
    case None{}: App.error(500, "route_error", "Missing key")

def operation(store: Db.Store, params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  operation_id(Router.param("id", params), store)

def health(params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  Web.json_value(200, Json.object([("status", Json.string("ok"))]))

# No effectful handler is called until the pure routing/authorization plan permits it.
def credential(value: Maybe<String>) -> Bool:
  match value:
    case Some{text}: String.eq(text, "allowed")
    case None{}: False{}

def execute(store: Db.Store, id: Nat, params: List<&2, C.Param>, request: Web.Incoming) -> IO(Web.Reply):
  match id:
    case 0n: health(Nil{}, request)
    case 1n: load(store, None{})
    case 2n: transfer(store, Nil{}, request)
    case 3n: operation_id(C.param("id", params), store)
    case 4n: load(store, None{})
    case other: App.error(500, "route_error", "Unknown route ID")

def route_allow(methods: List<&2, String>, reply: Web.Reply) -> Web.Reply:
  match methods:
    case Nil{}: reply
    case head <> tail: Web.with_header("Allow", App.allowed(head <> tail), reply)

def routed(store: Db.Store, request: Web.Incoming, decision: C.Decision<Unit, H.Access>) -> IO(Web.Reply):
  match decision:
    case C.Decision{state, C.Reply{status, H.Execute{id, params}}}: execute(store, id, params, request)
    case C.Decision{state, C.Error{status, code, methods}}:
      do IO<Web.Reply>:
        reply : Web.Reply <- App.error(U32.from_nat(status), code, "Request rejected")
        IO.pure(Web.Reply, route_allow(methods, reply))

def dispatch(store: Db.Store, +request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, path, target, headers, body}:
      routed(store, request, H.route(method, path, credential(Web.header("x-demo-access", headers))))

def handler(+store: Db.Store, request: Web.Incoming) -> IO(Web.Reply):
  App.observe(r => dispatch(store, r), request)

@unsafe
def serve(+store: Db.Store) -> IO(Unit):
  IO.bind(Web.Next, Unit, Web.Server.next(), Web.serve_next(r => handler(store, r), u => serve(store)))

def listening(store: Db.Store, result: Web.Started) -> IO(Unit):
  match result:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        serve(store)
    case Web.ListenError{code}: IO.die(Unit, 1, code)

def initialized(+store: Db.Store, port: U32, result: Db.WriteResult) -> IO(Unit):
  match result:
    case Db.StoreApplied{version}: IO.bind(Web.Started, Unit, Web.Server.listen(Web.config("127.0.0.1", port)), r => listening(store, r))
    case Db.StoreReplayed{version}: IO.bind(Web.Started, Unit, Web.Server.listen(Web.config("127.0.0.1", port)), r => listening(store, r))
    case other: IO.die(Unit, 1, "Ledger initialization failed; reconcile database")

def initial_encoded(+store: Db.Store, port: U32, result: Json.EncodeResult) -> IO(Unit):
  match result:
    case Json.JsonEncoded{body}:
      IO.bind(Db.WriteResult, Unit, Db.Store.compare_write(store, "ledger:init", "ledger", 0, body), r => initialized(store, port, r))
    case other: IO.die(Unit, 1, "Ledger encoding failed")

def opened(port: U32, result: Db.OpenResult) -> IO(Unit):
  match result:
    case Db.StoreReady{+store}:
      IO.bind(Json.EncodeResult, Unit, Json.Json.stringify(snapshot(E.initial(), Nil{})), r => initial_encoded(store, port, r))
    case Db.StoreOpenError{code, message}: IO.die(Unit, 1, code)

def start_port(path: String, port: Maybe<&2, U32>) -> IO(Unit):
  match port:
    case Some{n}: IO.bind(Db.OpenResult, Unit, Db.Store.open(path), r => opened(n, r))
    case None{}: IO.die(Unit, 2, "Invalid port")

def start(args: List<String>) -> IO(Unit):
  match args:
    case path <> port <> Nil{}: start_port(path, U32.read(port))
    case other: IO.die(Unit, 2, "usage: ledger DATABASE PORT")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    start(List.tail(&1, String, args))
