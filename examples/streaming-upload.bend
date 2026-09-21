import Base
import ../src/server.bend as Web

def finish(+id: U32, result: Web.Replied) -> IO(Unit):
  Web.Server.finish(id)

def completed(+id: U32, chunks: Nat) -> IO(Unit):
  do IO<Unit>:
    result : Web.Replied <- Web.Server.reply(id, Web.json(200,
      "{\"received_chunks\":" ++ Nat.show(chunks) ++ "}"))
    finish(id, result)

def failed(+id: U32, +code: String) -> IO(Unit):
  do IO<Unit>:
    # Parser-owned errors may already have started their JSON response. The
    # reply then returns response_started; finish still releases the budget.
    result : Web.Replied <- Web.Server.reply(id, Web.json(400,
      "{\"error\":{\"code\":\"invalid_body\",\"message\":\"Upload failed\"}}"))
    finish(id, result)

def consume_result(rest: Nat -> IO(Unit), id: U32, chunks: Nat, value: Web.BodyNext) -> IO(Unit):
  match value:
    case Web.BodyChunk{value}: rest(1n+chunks)
    case Web.BodyEnd{}: completed(id, chunks)
    case Web.BodyFailure{code}: failed(id, code)

@unsafe
def consume(+id: U32, chunks: Nat) -> IO(Unit):
  IO.bind(Web.BodyNext, Unit, Web.Server.body_next(id),
    consume_result(next => consume(id, next), id, chunks))

def handle(request: Web.IncomingHead) -> IO(Unit):
  match request:
    case Web.IncomingHead{+id, method, path, target, headers}: consume(id, 0n)

def next(rest: Unit -> IO(Unit), value: Web.StreamNext) -> IO(Unit):
  match value:
    case Web.StreamReceived{request}:
      do IO<Unit>:
        IO.spawn(Unit, handle(request))
        rest(Unit{})
    case Web.StreamStopped{}: IO.pure(Unit, Unit{})

@unsafe
def serve() -> IO(Unit):
  IO.bind(Web.StreamNext, Unit, Web.Server.next_stream(), next(u => serve()))

def start(value: Web.Started) -> IO(Unit):
  match value:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        serve()
    case Web.ListenError{code}: IO.die(Unit, 1, code)

def main() -> IO(Unit):
  do IO<Unit>:
    value : Web.Started <- Web.Server.listen_streaming_with_limits(
      Web.config("127.0.0.1", 8080), Web.TransportLimits{128, 10000})
    start(value)
