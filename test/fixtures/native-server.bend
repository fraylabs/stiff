import Base
import ../../src/json.bend as Json
import ../../src/server.bend as Web
import ../../examples/server.bend as Example

def header_reply(value: Maybe<String>) -> IO(Web.Reply):
  match value:
    case Some{text}: IO.pure(Web.Reply, Web.Reply{200, Nil{}, text})
    case None{}: IO.pure(Web.Reply, Web.json(400, "{}"))

def normal(found: Bool, path: String, headers: List<&2, Web.ServerHeader>, method: String, body: String) -> IO(Web.Reply):
  match found:
    case True{}: header_reply(Web.header("x-test", headers))
    case False{}: Example.route(method ++ " " ++ path, body)

def stop_route(found: Bool, +path: String, headers: List<&2, Web.ServerHeader>, method: String, body: String) -> IO(Web.Reply):
  match found:
    case True{}:
      do IO<Web.Reply>:
        Web.Server.stop()
        IO.pure(Web.Reply, Web.json(200, "{}"))
    case False{}: normal(String.eq(path, "/header"), path, headers, method, body)

def hung(found: Bool, +path: String, headers: List<&2, Web.ServerHeader>, method: String, body: String) -> IO(Web.Reply):
  match found:
    case True{}:
      do IO<Web.Reply>:
        IO.sleep(1500)
        IO.pure(Web.Reply, Web.json(200, "{}"))
    case False{}: stop_route(String.eq(path, "/stop"), path, headers, method, body)

def no_content(found: Bool, +path: String, headers: List<&2, Web.ServerHeader>, method: String, body: String) -> IO(Web.Reply):
  match found:
    case True{}: IO.pure(Web.Reply, Web.Reply{205, Nil{}, ""})
    case False{}: hung(String.eq(path, "/hung"), path, headers, method, body)

def bad_status(found: Bool, +path: String, headers: List<&2, Web.ServerHeader>, method: String, body: String) -> IO(Web.Reply):
  match found:
    case True{}: IO.pure(Web.Reply, Web.json(205, "{\"bad\":true}"))
    case False{}: no_content(String.eq(path, "/no-content"), path, headers, method, body)

def special(found: Bool, +path: String, headers: List<&2, Web.ServerHeader>, method: String, body: String) -> IO(Web.Reply):
  match found:
    case True{}: IO.pure(Web.Reply, Web.with_header("X-Bad", "secret\r\nInjected: yes", Web.json(200, "{}")))
    case False{}: bad_status(String.eq(path, "/bad-status"), path, headers, method, body)

def encode_failure(found: Bool, +path: String, headers: List<&2, Web.ServerHeader>, method: String, body: String) -> IO(Web.Reply):
  match found:
    case True{}:
      Web.json_value(200, Json.object([("same", Json.string("private-value")), ("same", Json.null())]))
    case False{}: special(String.eq(path, "/bad-response"), path, headers, method, body)

def handler(request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, +path, target, headers, body}:
      do IO<Web.Reply>:
        IO.print("HANDLING " ++ path)
        encode_failure(String.eq(path, "/encode-failure"), path, headers, method, body)

def start(result: Web.Started) -> IO(Unit):
  match result:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        Web.serve(~handler)
        Web.Server.stop()
        IO.print("STOPPED")
    case Web.ListenError{code}:
      IO.die(Unit, 1, code)

def main() -> IO(Unit):
  IO.bind(Web.Started, Unit, Web.Server.listen(Web.Config{"127.0.0.1", 0, 1024, 4, 1000, 600}), start)
