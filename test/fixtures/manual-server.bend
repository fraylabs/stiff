import Base
import ../../src/server.bend as Web

def inactive(active: Bool) -> IO(Unit):
  match active:
    case False{}: IO.print("RELEASED")
    case True{}: IO.die(Unit, 1, "finished request remained active")

def delay(slow: Bool) -> IO(Unit):
  match slow:
    case True{}: IO.sleep(1500)
    case False{}: IO.pure(Unit, Unit{})

def handle(request: Web.Incoming) -> IO(Unit):
  match request:
    case Web.Incoming{+id, method, path, target, headers, body}:
      do IO<Unit>:
        IO.print("HANDLING")
        delay(String.eq(path, "/hold"))
        reply : Web.Replied <- Web.Server.reply(id, Web.json(200, "{}"))
        Web.Server.finish(id)
        Web.Server.finish(id)
        active : Bool <- Web.Server.active(id)
        inactive(active)

def next(rest: Unit -> IO(Unit), value: Web.Next) -> IO(Unit):
  match value:
    case Web.Received{request}:
      do IO<Unit>:
        handle(request)
        rest(Unit{})
    case Web.Stopped{}: IO.pure(Unit, Unit{})

@unsafe
def serve() -> IO(Unit):
  IO.bind(Web.Next, Unit, Web.Server.next(), next(u => serve()))

def start(result: Web.Started) -> IO(Unit):
  match result:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        serve()
    case Web.ListenError{code}: IO.die(Unit, 1, code)

def main() -> IO(Unit):
  do IO<Unit>:
    Web.Server.finish(0)
    active : Bool <- Web.Server.active(0)
    inactive(active)
    result : Web.Started <- Web.Server.listen(Web.Config{"127.0.0.1", 0, 1024, 1, 1000, 600})
    start(result)
