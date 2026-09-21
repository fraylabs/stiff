import Base
import ../../src/server.bend as Web

def finish_reply(id: U32, result: Web.Replied) -> IO(Unit):
  do IO<Unit>:
    Web.Server.finish(id)

def complete(+id: U32, +body: String) -> IO(Unit):
  do IO<Unit>:
    sent : Web.Replied <- Web.Server.reply(id, Web.Reply{200,
      [Web.ServerHeader{"Content-Type", "text/plain"}], body})
    finish_reply(id, sent)

def metrics_reply(+id: U32, metrics: Web.Metrics) -> IO(Unit):
  match metrics:
    case Web.Metrics{admitted, completed, failed, rejected, expired, read_expired, disconnected, connections, pending, handlers}:
      do IO<Unit>:
        sent : Web.Replied <- Web.Server.reply(id, Web.json(200,
          "{\"pending\":" ++ U32.show(pending) ++ ",\"handlers\":" ++ U32.show(handlers) ++ "}"))
        finish_reply(id, sent)

def complete_metrics(+id: U32) -> IO(Unit):
  do IO<Unit>:
    metrics : Web.Metrics <- Web.Server.metrics()
    metrics_reply(id, metrics)

def complete_route(metrics: Bool, id: U32, body: String) -> IO(Unit):
  match metrics:
    case True{}: complete_metrics(id)
    case False{}: complete(id, body)

def failed(+id: U32, +code: String) -> IO(Unit):
  do IO<Unit>:
    sent : Web.Replied <- Web.Server.reply(id, Web.json(400,
      "{\"error\":{\"code\":\"invalid_body\",\"message\":\"Request body is invalid\"}}"))
    finish_reply(id, sent)

def consume_result(rest: String -> IO(Unit), id: U32, +path: String, +body: String, result: Web.BodyNext) -> IO(Unit):
  match result:
    case Web.BodyChunk{value}:
      do IO<Unit>:
        IO.print("CHUNK " ++ U32.show(id))
        IO.sleep(40)
        rest(body ++ value)
    case Web.BodyEnd{}: complete_route(String.eq(path, "/metrics"), id, body)
    case Web.BodyFailure{code}: failed(id, code)

@unsafe
def consume(+id: U32, +path: String, +body: String) -> IO(Unit):
  IO.bind(Web.BodyNext, Unit, Web.Server.body_next(id),
    consume_result(next => consume(id, path, next), id, path, body))

def handle_route(abandon: Bool, id: U32, path: String) -> IO(Unit):
  match abandon:
    case True{}: Web.Server.finish(id)
    case False{}: consume(id, path, "")

def handle(request: Web.IncomingHead) -> IO(Unit):
  match request:
    case Web.IncomingHead{+id, method, +path, target, headers}:
      handle_route(String.eq(path, "/abandon"), id, path)

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

def start(result: Web.Started) -> IO(Unit):
  match result:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        serve()
    case Web.ListenError{code}: IO.die(Unit, 1, code)

def main() -> IO(Unit):
  do IO<Unit>:
    result : Web.Started <- Web.Server.listen_streaming_with_limits(
      Web.Config{"127.0.0.1", 0, 131072, 8, 10000, 1000}, Web.TransportLimits{8, 2000})
    start(result)
