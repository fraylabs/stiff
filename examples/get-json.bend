import Base
import ../src/http.bend as Http
import ../src/io.bend as Net
import ../src/json.bend as Json

def print_field(value: Maybe<Json.Json>) -> IO(Unit):
  match value:
    case Some{Json.JsonString{title}}:
      IO.print(title)
    case other:
      IO.print("No string title in this JSON response.")

def print_slideshow(value: Maybe<Json.Json>) -> IO(Unit):
  match value:
    case Some{slideshow}:
      print_field(Json.field("title", slideshow))
    case None{}:
      IO.print("No slideshow in this JSON response.")

def show(result: Net.JsonResult) -> IO(Unit):
  match result:
    case Net.JsonOk{status, value}:
      do IO<Unit>:
        IO.print("HTTP " ++ U32.show(status))
        print_slideshow(Json.field("slideshow", value))
    case Net.JsonError{code, message}:
      IO.die(Unit, 1, code ++ ": " ++ message)

def url(args: List<String>) -> String:
  match args:
    case Con{head, tail}:
      head
    case Nil{}:
      "https://httpbin.org/json"

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    response : Net.JsonResult <- Net.Stiff.send_json(Http.get(url(args)))
    show(response)
