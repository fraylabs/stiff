import Base
import ../../src/server.bend as Web
import ../../src/app.bend as App
import ../../src/json.bend as Json
import ../../src/schema.bend as Schema
import ../../src/store.bend as Db
import ../../src/contracts.bend as C
import ./model.bend as M
import ./engine.bend as E
import ./spec.bend as S
import ./http.bend as H

def number(value: Maybe<&2, U32>) -> U32:
  match value:
    case Some{n}: n
    case None{}: 0

def uint(value: Maybe<Json.Json>) -> U32:
  match value:
    case Some{Json.JsonNumber{s}}: number(U32.read(s))
    case other: 0

def entries(value: Maybe<Json.Json>) -> List<&2, Json.Json>:
  match value:
    case Some{Json.JsonArray{items}}: items
    case other: Nil{}

def field(+value: Json.Json, name: String) -> Nat:
  U32.to_nat(uint(Json.field(name, value)))

def booking_schema() -> Schema.Schema:
  Schema.Object{[
    Schema.Field{"id", True{}, Schema.UInt{1, 1000000}},
    Schema.Field{"room", True{}, Schema.UInt{0, 2}},
    Schema.Field{"start", True{}, Schema.UInt{0, 1440}},
    Schema.Field{"end", True{}, Schema.UInt{1, 1440}}
  ], True{}}

def request_schema(+cancel: Bool) -> Schema.Schema:
  match cancel:
    case False{}:
      Schema.Object{[
        Schema.Field{"idempotency_key", True{}, Schema.UInt{1, 1000000}},
        Schema.Field{"expected_version", True{}, Schema.UInt{1, 4294967294}},
        Schema.Field{"room", True{}, Schema.UInt{0, 2}},
        Schema.Field{"start", True{}, Schema.UInt{0, 1440}},
        Schema.Field{"end", True{}, Schema.UInt{1, 1440}}
      ], True{}}
    case True{}:
      Schema.Object{[
        Schema.Field{"idempotency_key", True{}, Schema.UInt{1, 1000000}},
        Schema.Field{"expected_version", True{}, Schema.UInt{1, 4294967294}},
        Schema.Field{"id", True{}, Schema.UInt{1, 1000000}}
      ], True{}}

def stored_schema() -> Schema.Schema:
  Schema.Object{[
    Schema.Field{"bookings", True{}, Schema.Sequence{booking_schema(), 0n, 1000n}},
    Schema.Field{"keys", True{}, Schema.Sequence{Schema.UInt{1, 1000000}, 0n, 1000n}},
    Schema.Field{"receipts", True{}, Schema.Sequence{Schema.Object{[
      Schema.Field{"kind", True{}, Schema.Text{4n, 6n}},
      Schema.Field{"idempotency_key", True{}, Schema.UInt{1, 1000000}},
      Schema.Field{"expected_version", True{}, Schema.UInt{1, 4294967294}},
      Schema.Field{"id", False{}, Schema.UInt{1, 1000000}},
      Schema.Field{"room", False{}, Schema.UInt{0, 2}},
      Schema.Field{"start", False{}, Schema.UInt{0, 1440}},
      Schema.Field{"end", False{}, Schema.UInt{1, 1440}}
    ], True{}}, 0n, 1000n}}
  ], True{}}

def decode_bookings(values: List<&2, Json.Json>) -> List<&2, M.Booking>:
  match values:
    case Nil{}: Nil{}
    case +v <> tail: M.Booking{field(v, "id"), field(v, "room"), field(v, "start"), field(v, "end")} <> decode_bookings(tail)

def decode_keys(values: List<&2, Json.Json>) -> List<&2, Nat>:
  match values:
    case Nil{}: Nil{}
    case v <> tail: U32.to_nat(uint(Some{v})) <> decode_keys(tail)

def decode(+value: Json.Json) -> M.State:
  M.State{decode_bookings(entries(Json.field("bookings", value))), decode_keys(entries(Json.field("keys", value)))}

def booking_json(b: M.Booking) -> Json.Json:
  match b:
    case M.Booking{id, room, start, end}:
      Json.object([("id", Json.u32(U32.from_nat(id))), ("room", Json.u32(U32.from_nat(room))),
        ("start", Json.u32(U32.from_nat(start))), ("end", Json.u32(U32.from_nat(end)))])

def bookings_json(bs: List<&2, M.Booking>) -> List<&2, Json.Json>:
  match bs:
    case Nil{}: Nil{}
    case b <> tail: booking_json(b) <> bookings_json(tail)

def keys_json(keys: List<&2, Nat>) -> List<&2, Json.Json>:
  match keys:
    case Nil{}: Nil{}
    case k <> tail: Json.u32(U32.from_nat(k)) <> keys_json(tail)

def snapshot(state: M.State, receipts: List<&2, Json.Json>) -> Json.Json:
  match state:
    case M.State{bs, keys}: Json.object([("bookings", Json.array(bookings_json(bs))),
      ("keys", Json.array(keys_json(keys))), ("receipts", Json.array(receipts))])

def response(status: Nat, version: U32, replayed: Bool, state: M.State) -> IO(Web.Reply):
  match state:
    case M.State{bs, keys}:
      Web.json_value(U32.from_nat(status), Json.object([("version", Json.u32(version)),
        ("replayed", Json.boolean(replayed)), ("bookings", Json.array(bookings_json(bs)))]))

# Canonical order ensures identical concurrent requests produce identical SQLite inputs.
def canonical(+cancel: Bool, +v: Json.Json) -> Json.Json:
  match cancel:
    case False{}:
      Json.object([("kind", Json.string("book")),
        ("idempotency_key", Json.u32(uint(Json.field("idempotency_key", v)))),
        ("expected_version", Json.u32(uint(Json.field("expected_version", v)))),
        ("room", Json.u32(uint(Json.field("room", v)))),
        ("start", Json.u32(uint(Json.field("start", v)))),
        ("end", Json.u32(uint(Json.field("end", v))))])
    case True{}:
      Json.object([("kind", Json.string("cancel")),
        ("idempotency_key", Json.u32(uint(Json.field("idempotency_key", v)))),
        ("expected_version", Json.u32(uint(Json.field("expected_version", v)))),
        ("id", Json.u32(uint(Json.field("id", v))))])

def domain(+cancel: Bool, +v: Json.Json) -> H.Request:
  match cancel:
    case False{}: H.Book{field(v, "idempotency_key"), field(v, "room"), field(v, "start"), field(v, "end")}
    case True{}: H.Cancel{field(v, "id")}

def operation(+cancel: Bool, key: Nat) -> String:
  match cancel:
    case False{}: "book:" ++ Nat.show(key)
    case True{}: "cancel:" ++ Nat.show(key)

def kind(value: Maybe<Json.Json>) -> Bool:
  match value:
    case Some{Json.JsonString{s}}: String.eq(s, "cancel")
    case other: False{}

def same_bool(a: Bool, b: Bool) -> Bool:
  match a b:
    case True{} True{}: True{}
    case False{} False{}: True{}
    case other other_b: False{}

def receipt_hit(hit: Bool, v: Json.Json, rest: Maybe<Json.Json>) -> Maybe<Json.Json>:
  match hit:
    case True{}: Some{v}
    case False{}: rest

def receipt(values: List<&2, Json.Json>, +cancel: Bool, +key: Nat) -> Maybe<Json.Json>:
  match values:
    case Nil{}: None{}
    case +v <> tail:
      receipt_hit(Bool.and(same_bool(kind(Json.field("kind", v)), cancel), Nat.is_eq(field(v, "idempotency_key"), key)), v, receipt(tail, cancel, key))

# Compare normalized request fields, including expected version.
def same_request(+a: Json.Json, +b: Json.Json) -> Bool:
  Bool.and(Nat.is_eq(field(a, "idempotency_key"), field(b, "idempotency_key")),
    Bool.and(Nat.is_eq(field(a, "expected_version"), field(b, "expected_version")),
      Bool.and(Nat.is_eq(field(a, "room"), field(b, "room")),
        Bool.and(Nat.is_eq(field(a, "start"), field(b, "start")),
          Bool.and(Nat.is_eq(field(a, "end"), field(b, "end")), Nat.is_eq(field(a, "id"), field(b, "id")))))))

def replay(same: Bool, version: U32, state: M.State) -> IO(Web.Reply):
  match same:
    case True{}: response(200n, version, True{}, state)
    case False{}: App.error(409, "idempotency_conflict", "Key names a different request")

def written(+state: M.State, result: Db.WriteResult) -> IO(Web.Reply):
  match result:
    case Db.StoreApplied{version}: response(200n, version, False{}, state)
    case Db.StoreReplayed{version}: response(200n, version, True{}, state)
    case Db.StoreVersionConflict{version, value}: App.error(409, "version_conflict", "Read the current schedule before a new request")
    case Db.StoreReplayedVersionConflict{version, value}: App.error(409, "version_conflict", "This operation was rejected by version comparison")
    case Db.StoreMissingConflict{}: App.error(409, "missing_conflict", "Schedule is missing")
    case Db.StoreReplayedMissingConflict{}: App.error(409, "missing_conflict", "Schedule was missing")
    case Db.StoreIdempotencyConflict{}: App.error(409, "idempotency_conflict", "Key names a different transaction")
    case Db.StoreWriteError{code, message}: App.error(503, code, message)

def encoded(store: Db.Store, op: String, expected: U32, +state: M.State, result: Json.EncodeResult) -> IO(Web.Reply):
  match result:
    case Json.JsonEncoded{body}:
      IO.bind(Db.WriteResult, Web.Reply, Db.Store.compare_write(store, op, "bookings", expected, body), r => written(state, r))
    case Json.JsonEncodeFailure{code, message}: App.error(500, code, message)

def save(room: Bool, store: Db.Store, +cancel: Bool, +v: Json.Json, +state: M.State, receipts: List<&2, Json.Json>) -> IO(Web.Reply):
  match room:
    case False{}: App.error(409, "schedule_full", "Demo receipt limit reached")
    case True{}:
      IO.bind(Json.EncodeResult, Web.Reply, Json.Json.stringify(snapshot(state, v <> receipts)),
        r => encoded(store, operation(cancel, field(v, "idempotency_key")), uint(Json.field("expected_version", v)), state, r))

def decided(store: Db.Store, +cancel: Bool, +v: Json.Json, version: U32, +stored: Json.Json, decision: C.Decision<M.State, H.Body>) -> IO(Web.Reply):
  match decision:
    case C.Decision{state, C.Reply{status, H.Rejected{}}}: App.error(U32.from_nat(status), "booking_rejected", "Invalid slot or overlapping schedule")
    case C.Decision{state, C.Reply{status, H.Snapshot{True{}}}}: App.error(500, "stored_value_invalid", "Missing retained request")
    case C.Decision{+state, C.Reply{status, H.Snapshot{False{}}}}:
      save(Nat.is_lt(List.length(&2, Json.Json, entries(Json.field("receipts", stored))), 1000n), store, cancel, v, state, entries(Json.field("receipts", stored)))
    case C.Decision{state, C.Error{status, code, allow}}: App.error(U32.from_nat(status), code, "Request rejected")

def request_path(+cancel: Bool) -> String:
  match cancel:
    case False{}: "/bookings"
    case True{}: "/admin/cancellations"

def fresh(store: Db.Store, +cancel: Bool, +v: Json.Json, version: U32, +stored: Json.Json, previous: Maybe<Json.Json>) -> IO(Web.Reply):
  match previous:
    case Some{original}: replay(same_request(original, v), version, decode(stored))
    case None{}: decided(store, cancel, v, version, stored, H.decide("POST", request_path(cancel), True{}, decode(stored), domain(cancel, v)))


def valid_stored(valid: Bool, store: Db.Store, version: U32, +stored: Json.Json, +cancel: Bool, request: Maybe<Json.Json>) -> IO(Web.Reply):
  match valid:
    case False{}: App.error(500, "stored_value_invalid", "Stored schedule overlaps")
    case True{}:
      match request:
        case None{}: response(200n, version, False{}, decode(stored))
        case Some{+v}: fresh(store, cancel, v, version, stored, receipt(entries(Json.field("receipts", stored)), cancel, field(v, "idempotency_key")))

def state_safe(state: M.State) -> Bool:
  match state:
    case M.State{bs, keys}: S.safe(bs)

def schema_checked(verdict: Schema.Verdict, store: Db.Store, version: U32, +stored: Json.Json, +cancel: Bool, request: Maybe<Json.Json>) -> IO(Web.Reply):
  match verdict:
    case Schema.Invalid{path, code}: App.error(500, "stored_value_invalid", "Snapshot does not match schema")
    case Schema.Valid{}:
      valid_stored(state_safe(decode(stored)), store, version, stored, cancel, request)

def parsed(store: Db.Store, version: U32, +cancel: Bool, request: Maybe<Json.Json>, result: Json.ParseResult) -> IO(Web.Reply):
  match result:
    case Json.JsonFailure{code, message}: App.error(500, "stored_value_invalid", "Invalid stored JSON")
    case Json.JsonDone{+stored}: schema_checked(Schema.validate(stored_schema(), stored), store, version, stored, cancel, request)

def found(store: Db.Store, +cancel: Bool, request: Maybe<Json.Json>, result: Db.ReadResult) -> IO(Web.Reply):
  match result:
    case Db.StoreFound{version, body}: IO.bind(Json.ParseResult, Web.Reply, Json.Json.parse(body), r => parsed(store, version, cancel, request, r))
    case Db.StoreMissing{}: App.error(503, "schedule_missing", "Schedule is not initialized")
    case Db.StoreReadError{code, message}: App.error(503, code, message)

def load(+store: Db.Store, +cancel: Bool, request: Maybe<Json.Json>) -> IO(Web.Reply):
  IO.bind(Db.ReadResult, Web.Reply, Db.Store.read(store, "bookings"), r => found(store, cancel, request, r))

def write_request(store: Db.Store, +cancel: Bool, body: String) -> IO(Web.Reply):
  App.json_body(body, v => Schema.apply(request_schema(cancel), v, value => load(store, cancel, Some{canonical(cancel, value)})))

def credential(value: Maybe<String>) -> Bool:
  match value:
    case Some{s}: String.eq(s, "allowed")
    case None{}: False{}

def execute(store: Db.Store, id: Nat, request: Web.Incoming) -> IO(Web.Reply):
  match id:
    case 0n: load(store, False{}, None{})
    case 1n:
      match request:
        case Web.Incoming{id, method, path, target, headers, body}: write_request(store, False{}, body)
    case 2n:
      match request:
        case Web.Incoming{id, method, path, target, headers, body}: write_request(store, True{}, body)
    case other: App.error(500, "route_error", "Unknown route")

def route_allow(methods: List<&2, String>, reply: Web.Reply) -> Web.Reply:
  match methods:
    case Nil{}: reply
    case head <> tail: Web.with_header("Allow", App.allowed(head <> tail), reply)

def routed(store: Db.Store, request: Web.Incoming, decision: C.Decision<Unit, H.Access>) -> IO(Web.Reply):
  match decision:
    case C.Decision{state, C.Reply{status, H.Execute{id}}}: execute(store, id, request)
    case C.Decision{state, C.Error{status, code, methods}}:
      do IO<Web.Reply>:
        reply : Web.Reply <- App.error(U32.from_nat(status), code, "Request rejected")
        IO.pure(Web.Reply, route_allow(methods, reply))

def dispatch(store: Db.Store, +request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, path, target, headers, body}:
      routed(store, request, H.route(method, path, credential(Web.header("x-demo-access", headers))))

@unsafe
def serve(+store: Db.Store) -> IO(Unit):
  IO.bind(Web.Next, Unit, Web.Server.next(), Web.serve_next(r => App.observe(v => dispatch(store, v), r), u => serve(store)))

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
    case other: IO.die(Unit, 1, "Schedule initialization failed; reconcile database")

def initial_encoded(+store: Db.Store, port: U32, result: Json.EncodeResult) -> IO(Unit):
  match result:
    case Json.JsonEncoded{body}: IO.bind(Db.WriteResult, Unit, Db.Store.compare_write(store, "bookings:init", "bookings", 0, body), r => initialized(store, port, r))
    case other: IO.die(Unit, 1, "Initial encoding failed")

def opened(port: U32, result: Db.OpenResult) -> IO(Unit):
  match result:
    case Db.StoreReady{+store}: IO.bind(Json.EncodeResult, Unit, Json.Json.stringify(snapshot(E.initial(), Nil{})), r => initial_encoded(store, port, r))
    case Db.StoreOpenError{code, message}: IO.die(Unit, 1, code)

def start_port(path: String, port: Maybe<&2, U32>) -> IO(Unit):
  match port:
    case Some{n}: IO.bind(Db.OpenResult, Unit, Db.Store.open(path), r => opened(n, r))
    case None{}: IO.die(Unit, 2, "Invalid port")

def start(args: List<String>) -> IO(Unit):
  match args:
    case path <> port <> Nil{}: start_port(path, U32.read(port))
    case other: IO.die(Unit, 2, "usage: bookings DATABASE PORT")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    start(List.tail(&1, String, args))
