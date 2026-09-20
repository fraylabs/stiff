import Base
import ./deps/stiff/src/http.bend as Http
import ./deps/stiff/src/io.bend as Net
import ./deps/stiff/src/json.bend as Json

def print_message(value: Maybe<Json.Json>) -> IO(Unit):
  match value:
    case Some{Json.JsonString{message}}:
      IO.print(message)
    case other:
      IO.print("JSON received (no string message field).")

def show_success(success: Bool, status: U32, value: Json.Json) -> IO(Unit):
  match success:
    case True{}:
      do IO<Unit>:
        IO.print("HTTP " ++ U32.show(status))
        print_message(Json.field("message", value))
    case False{}:
      IO.die(Unit, 1, "HTTP " ++ U32.show(status))

def show(result: Net.JsonResult) -> IO(Unit):
  match result:
    case Net.JsonOk{+status, value}:
      show_success(Http.is_success(status), status, value)
    case Net.JsonError{code, message}:
      IO.die(Unit, 1, code ++ ": " ++ message)

def run(args: List<String>) -> IO(Unit):
  match args:
    case Con{url, Nil{}}:
      do IO<Unit>:
        token : String <- IO.try(String, IO.get_env("STIFF_TOKEN"))
        result : Net.JsonResult <- Net.Stiff.send_json(
          Http.with_bearer(token, Http.with_header("User-Agent", "stiff-auth-example", Http.get(url))))
        show(result)
    case other:
      IO.die(Unit, 2, "Usage: auth-client https://your-api.example/resource (set STIFF_TOKEN)")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
