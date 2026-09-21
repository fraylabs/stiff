import Base
import ../../src/app.bend as App
import ../../src/server.bend as Web
import ../../src/json.bend as Json
import ../../examples/app.bend as Example

def slow(found: Bool, request: Web.Incoming) -> IO(Web.Reply):
  match found:
    case True{}:
      do IO<Web.Reply>:
        IO.print("SLOW")
        IO.sleep(600)
        IO.pure(Web.Reply, Web.json(200, "{}"))
    case False{}: Example.gate(request)

def route(request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, +path, target, headers, body}:
      slow(String.eq(path, "/slow"), Web.Incoming{id, method, path, target, headers, body})

def handler(request: Web.Incoming) -> IO(Web.Reply):
  App.observe(route, request)

def printed(result: Json.EncodeResult) -> IO(Unit):
  match result:
    case Json.JsonEncoded{text}: IO.print(text)
    case Json.JsonEncodeFailure{code, message}: IO.die(Unit, 1, code)

def start(result: Web.Started) -> IO(Unit):
  match result:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        Web.serve(~handler)
        IO.sleep(650)
        snapshot : Web.Metrics <- Web.Server.metrics()
        encoded : Json.EncodeResult <- Json.Json.stringify(Web.metrics_json(snapshot))
        printed(encoded)
    case Web.ListenError{code}: IO.die(Unit, 1, code)

def main() -> IO(Unit):
  IO.bind(Web.Started, Unit,
    Web.Server.listen_with_limits(Web.Config{"127.0.0.1", 0, 1024, 3, 200, 100}, Web.TransportLimits{8, 160}), start)
