import Base
import ../src/server.bend as Web
import ../src/json.bend as Json

def message(status: U32, key: String, text: String) -> IO(Web.Reply):
  Web.json_value(status, Json.object([(key, Json.string(text))]))

def echo(parsed: Json.ParseResult) -> IO(Web.Reply):
  match parsed:
    case Json.JsonDone{value}: Web.json_value(200, value)
    case other: message(400, "error", "invalid JSON")

def inspect(parsed: Json.ParseResult) -> IO(Web.Reply):
  match parsed:
    case Json.JsonDone{value}:
      Web.json_value(200, Json.object([
        ("received", value),
        ("accepted", Json.boolean(True{})),
        ("labels", Json.array([Json.string("native"), Json.string("Bend")]))]))
    case other: message(400, "error", "invalid JSON")

def inspect_route(found: Bool, body: String) -> IO(Web.Reply):
  match found:
    case True{}: IO.bind(Json.ParseResult, Web.Reply, Json.Json.parse(body), inspect)
    case False{}: message(404, "error", "not found")

def echo_route(found: Bool, key: String, body: String) -> IO(Web.Reply):
  match found:
    case True{}: IO.bind(Json.ParseResult, Web.Reply, Json.Json.parse(body), echo)
    case False{}: inspect_route(String.eq(key, "POST /inspect"), body)

def slow_route(found: Bool, +key: String, body: String) -> IO(Web.Reply):
  match found:
    case True{}:
      do IO<Web.Reply>:
        IO.sleep(250)
        message(200, "message", "finished")
    case False{}: echo_route(String.eq(key, "POST /echo"), key, body)

def health_route(found: Bool, +key: String, body: String) -> IO(Web.Reply):
  match found:
    case True{}:
      do IO<Web.Reply>:
        reply : Web.Reply <- message(200, "message", "healthy")
        IO.pure(Web.Reply, Web.with_header("X-Stiff", "native", reply))
    case False{}: slow_route(String.eq(key, "GET /slow"), key, body)

def route(+key: String, body: String) -> IO(Web.Reply):
  health_route(String.eq(key, "GET /health"), key, body)

def handler(request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, path, target, headers, body}:
      route(method ++ " " ++ path, body)

def start(result: Web.Started) -> IO(Unit):
  match result:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        Web.serve(~handler)
        IO.print("STOPPED")
    case Web.ListenError{code}:
      IO.die(Unit, 1, code)

def port(value: Maybe<&2, U32>) -> U32:
  match value:
    case Some{n}: n
    case None{}: 65536

def config(args: List<String>) -> Web.Config:
  match args:
    case Con{address, Con{p, Nil{}}}:
      Web.config(address, port(U32.read(p)))
    case Nil{}:
      Web.config("127.0.0.1", 8080)
    case other:
      Web.config("invalid", 0)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    result : Web.Started <- Web.Server.listen(config(args))
    start(result)
