import Base
import ./deps/stiff/src/server.bend as Web
import ./deps/stiff/src/app.bend as App
import ./deps/stiff/src/contracts.bend as C
import ./api.bend as Api

def allow(methods: List<&2, String>, reply: Web.Reply) -> Web.Reply:
  match methods:
    case Nil{}: reply
    case head <> tail: Web.with_header("Allow", App.allowed(head <> tail), reply)

def render(decision: C.Decision<Nat, String>) -> IO(Web.Reply):
  match decision:
    case C.Decision{state, C.Reply{status, body}}:
      IO.pure(Web.Reply, Web.Reply{U32.from_nat(status), [Web.ServerHeader{"Content-Type", "text/plain; charset=utf-8"}], body})
    case C.Decision{state, C.Error{status, code, methods}}:
      do IO<Web.Reply>:
        reply : Web.Reply <- App.error(U32.from_nat(status), code, "Request rejected")
        IO.pure(Web.Reply, allow(methods, reply))

def dispatch(request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, path, target, headers, body}: render(Api.decide(method, path, 0n))

@unsafe
def serve() -> IO(Unit):
  IO.bind(Web.Next, Unit, Web.Server.next(), Web.serve_next(r => App.observe(dispatch, r), u => serve()))

def listening(result: Web.Started) -> IO(Unit):
  match result:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        serve()
    case Web.ListenError{code}: IO.die(Unit, 1, code)

def port(value: Maybe<&2, U32>) -> IO(Unit):
  match value:
    case Some{n}: IO.bind(Web.Started, Unit, Web.Server.listen(Web.config("127.0.0.1", n)), listening)
    case None{}: IO.die(Unit, 2, "Invalid port")

def start(args: List<String>) -> IO(Unit):
  match args:
    case p <> Nil{}: port(U32.read(p))
    case other: IO.die(Unit, 2, "usage: @NAME@ PORT")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    start(List.tail(&1, String, args))
