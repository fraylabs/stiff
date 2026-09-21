import Base
import ./server.bend as Web
import ./json.bend as Json

type Route is Type:
  Route{method: String, path: String, handler: Web.Incoming -> IO(Web.Reply)}

type Selection is Type:
  Found{handler: Web.Incoming -> IO(Web.Reply)}
  Missing{}
  WrongMethod{methods: List<&2, String>}

def contains_step(found: Bool, rest: Unit -> Bool) -> Bool:
  match found:
    case True{}: True{}
    case False{}: rest(Unit{})

def contains(+name: String, names: List<&2, String>) -> Bool:
  match names:
    case Nil{}: False{}
    case Con{head, tail}: contains_step(String.eq(name, head), u => contains(name, tail))

def unique(found: Bool, name: String, names: List<&2, String>) -> List<&2, String>:
  match found:
    case True{}: names
    case False{}: name <> names

def add_allowed(+method: String, selection: Selection) -> Selection:
  match selection:
    case Found{handler}: Found{handler}
    case Missing{}: WrongMethod{[method]}
    case WrongMethod{+methods}: WrongMethod{unique(contains(method, methods), method, methods)}

def choose_method(matches: Bool, method: String, handler: Web.Incoming -> IO(Web.Reply), rest: Unit -> Selection) -> Selection:
  match matches:
    case True{}: Found{handler}
    case False{}: add_allowed(method, rest(Unit{}))

def choose_path(matches: Bool, same_method: Bool, method: String, handler: Web.Incoming -> IO(Web.Reply), rest: Unit -> Selection) -> Selection:
  match matches:
    case True{}: choose_method(same_method, method, handler, rest)
    case False{}: rest(Unit{})

# Exact, case-sensitive matches. The first matching method/path wins.
def select(routes: List<Route>, +method: String, +path: String) -> Selection:
  match routes:
    case Nil{}: Missing{}
    case Con{Route{+verb, location, handler}, tail}:
      choose_path(String.eq(path, location), String.eq(method, verb), verb, handler,
        u => select(tail, method, path))

def error(status: U32, code: String, message: String) -> IO(Web.Reply):
  Web.json_value(status, Json.object([("error", Json.object([
    ("code", Json.string(code)), ("message", Json.string(message))]))]))

def allowed_tail(methods: List<&2, String>) -> String:
  match methods:
    case Nil{}: ""
    case Con{method, tail}: ", " ++ method ++ allowed_tail(tail)

def allowed(methods: List<&2, String>) -> String:
  match methods:
    case Nil{}: ""
    case Con{method, tail}: method ++ allowed_tail(tail)

def selected(selection: Selection, request: Web.Incoming) -> IO(Web.Reply):
  match selection:
    case Found{handler}: handler(request)
    case Missing{}: error(404, "not_found", "No route matches this path")
    case WrongMethod{methods}:
      do IO<Web.Reply>:
        reply : Web.Reply <- error(405, "method_not_allowed", "Method not allowed for this path")
        IO.pure(Web.Reply, Web.with_header("Allow", allowed(methods), reply))

def route(routes: List<Route>, request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, +method, +path, target, headers, body}:
      selected(select(routes, method, path), Web.Incoming{id, method, path, target, headers, body})

# Middleware is an ordinary function taking the next handler and the request.
def with_header(name: String, value: String, next: Web.Incoming -> IO(Web.Reply), request: Web.Incoming) -> IO(Web.Reply):
  do IO<Web.Reply>:
    reply : Web.Reply <- next(request)
    IO.pure(Web.Reply, Web.with_header(name, value, reply))

# Rejected requests never evaluate the supplied continuation.
def guard(allowed: Bool, status: U32, code: String, message: String, next: Unit -> IO(Web.Reply)) -> IO(Web.Reply):
  match allowed:
    case True{}: next(Unit{})
    case False{}: error(status, code, message)

def parsed(next: Json.Json -> IO(Web.Reply), result: Json.ParseResult) -> IO(Web.Reply):
  match result:
    case Json.JsonDone{value}: next(value)
    case Json.JsonFailure{code, message}: error(400, "invalid_json", "Request body must be valid JSON")

def json_body(body: String, next: Json.Json -> IO(Web.Reply)) -> IO(Web.Reply):
  IO.bind(Json.ParseResult, Web.Reply, Json.Json.parse(body), parsed(next))

type TextResult is Data:
  TextValid{value: String}
  TextInvalid{field: String, code: String}

def text_length(valid: Bool, field: String, value: String) -> TextResult:
  match valid:
    case True{}: TextValid{value}
    case False{}: TextInvalid{field, "length"}

def text_value(field: String, min: Nat, max: Nat, value: Json.Json) -> TextResult:
  match value:
    case Json.JsonString{+text}:
      text_length(Bool.and(Nat.is_ge(String.length(text), min), Nat.is_le(String.length(text), max)), field, text)
    case other: TextInvalid{field, "type"}

def text_field(field: String, min: Nat, max: Nat, value: Maybe<Json.Json>) -> TextResult:
  match value:
    case Some{item}: text_value(field, min, max, item)
    case None{}: TextInvalid{field, "required"}

# Inclusive Unicode code-point lengths; no whitespace trimming or normalization.
def required_text(+field: String, min: Nat, max: Nat, value: Json.Json) -> TextResult:
  match value:
    case Json.JsonObject{entries}: text_field(field, min, max, Json.lookup(field, entries))
    case other: TextInvalid{field, "object_required"}

def validation_error(field: String, code: String) -> IO(Web.Reply):
  Web.json_value(422, Json.object([("error", Json.object([
    ("code", Json.string("validation_failed")),
    ("message", Json.string("Request validation failed")),
    ("field", Json.string(field)), ("reason", Json.string(code))]))]))

# One JSON line per completed handler invocation, before transport submission.
# Intentionally omit user-controlled paths, targets, headers and bodies.
def log_encoded(result: Json.EncodeResult) -> IO(Unit):
  match result:
    case Json.JsonEncoded{text}: IO.print_err(text)
    case Json.JsonEncodeFailure{code, message}:
      IO.print_err("{\"event\":\"log_encoding_failed\"}")

def observed(+id: U32, method: String, start: Nat, reply: Web.Reply) -> IO(Web.Reply):
  match reply:
    case Web.Reply{+status, headers, body}:
      do IO<Web.Reply>:
        end : Nat <- IO.now()
        active : Bool <- Web.Server.active(id)
        record : Json.EncodeResult <- Json.Json.stringify(Json.object([
          ("event", Json.string("handler_result")),
          ("request_id", Json.string(U32.show(id))),
          ("method", Json.string(method)), ("proposed_status", Json.u32(status)),
          ("active", Json.boolean(active)),
          ("duration_ms", Json.JsonNumber{Nat.show(Nat.sub(end, start))})]))
        log_encoded(record)
        IO.pure(Web.Reply, Web.with_header("X-Request-Id", U32.show(id), Web.Reply{status, headers, body}))

def observe(next: Web.Incoming -> IO(Web.Reply), request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{+id, +method, path, target, headers, body}:
      do IO<Web.Reply>:
        start : Nat <- IO.now()
        reply : Web.Reply <- next(Web.Incoming{id, method, path, target, headers, body})
        observed(id, method, start, reply)
