import Base
import ../src/server.bend as Web
import ../examples/server.bend as Example

def route(hold: Bool, key: String, body: String) -> IO(Web.Reply):
  match hold:
    case True{}:
      do IO<Web.Reply>:
        IO.print("HOLD")
        IO.sleep(1500)
        IO.pure(Web.Reply, Web.json(200, "{}"))
    case False{}: Example.route(key, body)

def handler(request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, +path, target, headers, body}:
      route(String.eq(path, "/hold"), method ++ " " ++ path, body)

def start(result: Web.Started) -> IO(Unit):
  match result:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        Web.serve(~handler)
        IO.print("STOPPED")
    case Web.ListenError{code}: IO.die(Unit, 1, code)

def main() -> IO(Unit):
  IO.bind(Web.Started, Unit, Web.Server.listen(Web.Config{"127.0.0.1", 0, 4096, 32, 5000, 3000}), start)
