import Base
import ../../src/server.bend as Web

def require(result: Web.Replied) -> IO(Unit):
  match result:
    case Web.Sent{}: IO.pure(Unit, Unit{})
    case Web.ReplyError{code}: IO.die(Unit, 1, code)

def finish_stream(+id: U32) -> IO(Unit):
  do IO<Unit>:
    result : Web.Replied <- Web.Server.stream_end(id)
    require(result)
    Web.Server.finish(id)

def delayed_second(+id: U32) -> IO(Unit):
  do IO<Unit>:
    IO.sleep(300)
    result : Web.Replied <- Web.Server.stream_write(id, "beta")
    require(result)
    finish_stream(id)

def chunks(+id: U32, connection: Web.ConnectionMode) -> IO(Unit):
  do IO<Unit>:
    result : Web.Replied <- Web.Server.stream_start(id, Web.StreamHead{200,
      [Web.ServerHeader{"Content-Type", "text/plain"}], connection})
    require(result)
    first : Web.Replied <- Web.Server.stream_write(id, "alpha")
    require(first)
    delayed_second(id)

def events(+id: U32) -> IO(Unit):
  do IO<Unit>:
    result : Web.Replied <- Web.Server.stream_start(id, Web.sse_head(Web.KeepAlive{}))
    require(result)
    first : Web.Replied <- Web.Server.stream_write(id, "event: ready\ndata: one\n\n")
    require(first)
    IO.sleep(30)
    second : Web.Replied <- Web.Server.stream_write(id, "data: two\n\n")
    require(second)
    finish_stream(id)

def ordinary(+id: U32) -> IO(Unit):
  do IO<Unit>:
    result : Web.Replied <- Web.Server.reply(id, Web.json(200, "{\"ok\":true}"))
    require(result)
    Web.Server.finish(id)

def empty_chunk(+id: U32) -> IO(Unit):
  do IO<Unit>:
    started : Web.Replied <- Web.Server.stream_start(id, Web.StreamHead{200,
      [Web.ServerHeader{"Content-Type", "text/plain"}], Web.CloseAfter{}})
    require(started)
    empty : Web.Replied <- Web.Server.stream_write(id, "")
    require(empty)
    value : Web.Replied <- Web.Server.stream_write(id, "ok")
    require(value)
    finish_stream(id)

def doubled(+text: String) -> String:
  text ++ text

def large_body(depth: Nat) -> String:
  match depth:
    case 0n: "0123456789abcdef"
    case 1n+rest: doubled(large_body(rest))

def expected_limit(found: Bool, id: U32) -> IO(Unit):
  match found:
    case True{}: finish_stream(id)
    case False{}: IO.die(Unit, 1, "unexpected stream limit error")

def limited_result(result: Web.Replied, id: U32) -> IO(Unit):
  match result:
    case Web.Sent{}: IO.die(Unit, 1, "stream exceeded aggregate limit")
    case Web.ReplyError{code}: expected_limit(String.eq(code, "response_too_large"), id)

def limited(+id: U32) -> IO(Unit):
  do IO<Unit>:
    result : Web.Replied <- Web.Server.stream_start(id, Web.StreamHead{200,
      [Web.ServerHeader{"Content-Type", "text/plain"}], Web.CloseAfter{}})
    require(result)
    full : Web.Replied <- Web.Server.stream_write(id, large_body(20n))
    require(full)
    extra : Web.Replied <- Web.Server.stream_write(id, "x")
    limited_result(extra, id)

def write_finished(+id: U32, result: Web.Replied) -> IO(Unit):
  match result:
    case Web.Sent{}: finish_stream(id)
    case Web.ReplyError{code}: Web.Server.finish(id)

def write_large(+id: U32) -> IO(Unit):
  do IO<Unit>:
    result : Web.Replied <- Web.Server.stream_write(id, large_body(18n))
    write_finished(id, result)

def pending_code(found: Bool, +code: String) -> IO(Unit):
  match found:
    case True{}: IO.print("PENDING " ++ code)
    case False{}: IO.die(Unit, 1, "concurrent response write was accepted")

def pending_result(result: Web.Replied) -> IO(Unit):
  match result:
    case Web.Sent{}: IO.die(Unit, 1, "concurrent response write was accepted")
    case Web.ReplyError{+code}: pending_code(String.eq(code, "response_write_pending"), code)

def concurrent(+id: U32) -> IO(Unit):
  do IO<Unit>:
    started : Web.Replied <- Web.Server.stream_start(id, Web.StreamHead{200,
      [Web.ServerHeader{"Content-Type", "text/plain"}], Web.CloseAfter{}})
    require(started)
    IO.spawn(Unit, write_large(id))
    IO.sleep(20)
    second : Web.Replied <- Web.Server.stream_write(id, "overlap")
    pending_result(second)

def reset_during_write(+id: U32) -> IO(Unit):
  do IO<Unit>:
    started : Web.Replied <- Web.Server.stream_start(id, Web.StreamHead{200,
      [Web.ServerHeader{"Content-Type", "text/plain"}], Web.CloseAfter{}})
    require(started)
    result : Web.Replied <- Web.Server.stream_write(id, large_body(18n))
    write_finished(id, result)

def empty_route(found: Bool, id: U32, +path: String) -> IO(Unit):
  match found:
    case True{}: empty_chunk(id)
    case False{}: ordinary(id)

def limit_route(found: Bool, id: U32, +path: String) -> IO(Unit):
  match found:
    case True{}: limited(id)
    case False{}: empty_route(String.eq(path, "/empty"), id, path)

def reset_route(found: Bool, id: U32, +path: String) -> IO(Unit):
  match found:
    case True{}: reset_during_write(id)
    case False{}: limit_route(String.eq(path, "/limit"), id, path)

def concurrent_route(found: Bool, id: U32, +path: String) -> IO(Unit):
  match found:
    case True{}: concurrent(id)
    case False{}: reset_route(String.eq(path, "/write-reset"), id, path)

def events_route(found: Bool, id: U32, +path: String) -> IO(Unit):
  match found:
    case True{}: events(id)
    case False{}: concurrent_route(String.eq(path, "/concurrent"), id, path)

def close_route(found: Bool, id: U32, +path: String) -> IO(Unit):
  match found:
    case True{}: chunks(id, Web.CloseAfter{})
    case False{}: events_route(String.eq(path, "/events"), id, path)

def route(found: Bool, id: U32, +path: String) -> IO(Unit):
  match found:
    case True{}: chunks(id, Web.KeepAlive{})
    case False{}: close_route(String.eq(path, "/stream-close"), id, path)

def handle(request: Web.Incoming) -> IO(Unit):
  match request:
    case Web.Incoming{+id, method, +path, target, headers, body}:
      route(String.eq(path, "/stream"), id, path)

def next(rest: Unit -> IO(Unit), value: Web.Next) -> IO(Unit):
  match value:
    case Web.Received{request}:
      do IO<Unit>:
        IO.spawn(Unit, handle(request))
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
    result : Web.Started <- Web.Server.listen_with_limits(
      Web.Config{"127.0.0.1", 0, 1024, 4, 10000, 1000}, Web.TransportLimits{8, 500})
    start(result)
