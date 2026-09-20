import Base
import ../../src/json.bend as Json

def boolean(value: Bool) -> String:
  match value:
    case True{}: "true"
    case False{}: "false"

def describe(value: Json.Json) -> String:
  match value:
    case Json.JsonNull{}: "null"
    case Json.JsonBool{value}: boolean(value)
    case Json.JsonNumber{decimal}: decimal
    case Json.JsonString{value}: value
    case Json.JsonArray{items}: "array"
    case Json.JsonObject{entries}: "object"

def field(value: Maybe<Json.Json>) -> String:
  match value:
    case Some{value}: describe(value)
    case None{}: "missing"

def show(result: Json.ParseResult) -> IO(Unit):
  match result:
    case Json.JsonDone{+value}:
      IO.print(describe(value) ++ ":" ++ field(Json.field("key", value)))
    case Json.JsonFailure{code, message}:
      IO.die(Unit, 1, code)

def first(args: List<String>) -> String:
  match args:
    case Con{head, tail}: head
    case Nil{}: "null"

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    value : Json.ParseResult <- Json.Json.parse(first(args))
    show(value)
