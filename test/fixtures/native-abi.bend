import Base
import ../../src/json.bend as Json
import ../../src/url.bend as Url

# These entry-module names must not capture the imported effects' constructors.
type Shadow is Data:
  JsonBool{left: U32, right: U32}
  UrlReady{}

def shadow(value: Shadow) -> String:
  match value:
    case JsonBool{left, right}: U32.show((left + right : U32))
    case UrlReady{}: "shadow"

def encoded(result: Json.EncodeResult) -> IO(Unit):
  match result:
    case Json.JsonEncoded{text}: IO.print(text)
    case Json.JsonEncodeFailure{code, message}: IO.die(Unit, 1, code)

def url(result: Url.UrlResult) -> IO(Unit):
  match result:
    case Url.UrlReady{text}: IO.print(text)
    case Url.UrlError{code}: IO.die(Unit, 1, code)

def argument(args: List<String>) -> IO(Unit):
  match args:
    case Con{program, Con{value, Nil{}}}: IO.print(value)
    case other: IO.die(Unit, 1, "unexpected arguments")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    argument(args)
    IO.print(shadow(JsonBool{2, 3}))
    IO.print(shadow(UrlReady{}))
    json : Json.EncodeResult <- Json.Json.stringify(Json.boolean(True{}))
    encoded(json)
    result : Url.UrlResult <- Url.Url.encode_component("🌱 &")
    url(result)
