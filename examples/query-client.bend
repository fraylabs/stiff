import Base
import ../src/http.bend as Http
import ../src/io.bend as Net
import ../src/url.bend as Url

def show(result: Net.HttpResult) -> IO(Unit):
  match result:
    case Net.HttpOk{Net.Response{status, body, headers}}:
      IO.print(U32.show(status) ++ ":" ++ body)
    case Net.HttpError{code, message}:
      IO.die(Unit, 1, code)

def send(result: Url.UrlResult) -> IO(Unit):
  match result:
    case Url.UrlReady{text}:
      IO.bind(Net.HttpResult, Unit, Net.Stiff.send(Http.get(text)), show)
    case Url.UrlError{code}:
      IO.die(Unit, 1, code)

def run(args: List<String>) -> IO(Unit):
  match args:
    case Con{base, Con{query, Nil{}}}:
      IO.bind(Url.UrlResult, Unit, Url.Url.with_query(base, [
        Url.QueryParam{"q", query},
        Url.QueryParam{"tag", "a"},
        Url.QueryParam{"tag", "b"}]), send)
    case other:
      IO.die(Unit, 1, "Usage: query-client URL SEARCH-TEXT")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
