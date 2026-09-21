import Base
import ../src/http.bend as Http
import ../src/io.bend as Net

# Use a caller-supplied test endpoint. This example sends real update/delete requests.
def choose(method: String, url: String) -> Maybe<Http.Request>:
  match method:
    case "PUT": Some{Http.put_json(url, "{\"message\":\"🌱\"}")}
    case "PATCH": Some{Http.patch_json(url, "{\"message\":\"🌱\"}")}
    case "DELETE": Some{Http.delete(url)}
    case "HEAD": Some{Http.with_max_bytes(1, Http.head(url))}
    case other: None{}

def show(result: Net.HttpResult) -> IO(Unit):
  match result:
    case Net.HttpOk{Net.Response{status, body, headers}}:
      IO.print(U32.show(status) ++ ":" ++ body)
    case Net.HttpError{code, message}:
      IO.die(Unit, 1, code)

def send(request: Maybe<Http.Request>) -> IO(Unit):
  match request:
    case Some{value}:
      do IO<Unit>:
        result : Net.HttpResult <- Net.Stiff.send(Http.with_bearer("synthetic-test-token", value))
        show(result)
    case None{}:
      IO.die(Unit, 1, "Expected PUT, PATCH, DELETE or HEAD")

def run(args: List<String>) -> IO(Unit):
  match args:
    case Con{url, Con{method, Nil{}}}:
      send(choose(method, url))
    case other:
      IO.die(Unit, 1, "Usage: methods URL PUT|PATCH|DELETE|HEAD")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
