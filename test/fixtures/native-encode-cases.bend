import Base
import ../../src/json.bend as Json

def show(result: Json.EncodeResult) -> IO(Unit):
  match result:
    case Json.JsonEncoded{text}: IO.print(text)
    case Json.JsonEncodeFailure{code, message}: IO.print(code)

def nested(depth: Nat) -> Json.Json:
  match depth:
    case 0n: Json.null()
    case 1n+rest: Json.array([nested(rest)])

def check(value: Json.Json, limit: U32) -> IO(Unit):
  IO.bind(Json.EncodeResult, Unit, Json.Json.stringify_with_limit(value, limit), show)

def main() -> IO(Unit):
  do IO<Unit>:
    check(Json.string("\n"), 8)
    check(Json.string("\n"), 7)
    check(Json.object([("same", Json.null()), ("same", Json.u32(1))]), 100)
    check(Json.object([("bad\0key", Json.null())]), 100)
    check(Json.string("\u{d800}"), 100)
    check(Json.string("\u{110000}"), 100)
    check(nested(129n), 1000)
    check(Json.null(), 0)
    check(Json.null(), 16777217)
    check(Json.array([]), 2)
    check(Json.object([]), 2)
    check(Json.object([("\"\\\n🌱", Json.string("value"))]), 100)
    check(Json.array([Json.object([("bad\0", Json.null())]), Json.array([Json.string("discarded")])]), 100)
    check(Json.object([("long", Json.array([Json.string("a"), Json.string("b")]))]), 5)
    check(Json.string("🌱"), 6)
    check(Json.string("🌱"), 5)
    check(Json.string("still usable"), 100)
