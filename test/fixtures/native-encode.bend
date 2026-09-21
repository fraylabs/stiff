import Base
import ../../src/json.bend as Json

def show(result: Json.EncodeResult) -> IO(Unit):
  match result:
    case Json.JsonEncoded{text}: IO.print(text)
    case Json.JsonEncodeFailure{code, message}: IO.die(Unit, 1, code)

def parsed(result: Json.ParseResult) -> IO(Unit):
  match result:
    case Json.JsonDone{value}: IO.bind(Json.EncodeResult, Unit, Json.Json.stringify(value), show)
    case Json.JsonFailure{code, message}: IO.die(Unit, 1, code)

def run(args: List<String>) -> IO(Unit):
  match args:
    case Con{value, Nil{}}:
      IO.bind(Json.ParseResult, Unit, Json.Json.parse(value), parsed)
    case Con{value, Con{mode, Nil{}}}:
      IO.bind(Json.EncodeResult, Unit, Json.Json.stringify(Json.JsonNumber{value}), show)
    case other:
      IO.bind(Json.EncodeResult, Unit, Json.Json.stringify(Json.object([
        ("string", Json.string("quote\" slash\\ newline\n tab\t null\0 🌱")),
        ("array", Json.array([Json.boolean(True{}), Json.boolean(False{}), Json.null(), Json.u32(42)]))])), show)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
