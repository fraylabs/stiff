import Base
import ../../src/http.bend as Http
import ../../src/io.bend as Net

def headers(args: List<String>, request: Http.Request) -> Http.Request:
  match args:
    case Con{name, Con{value, tail}}:
      headers(tail, Http.with_header(name, value, request))
    case other:
      request

def request(args: List<String>) -> Http.Request:
  match args:
    case Con{url, Con{method, Con{body, tail}}}:
      headers(tail, Http.Request{method, url, body, 2000, 1048576, Nil{}})
    case other:
      Http.get("http://127.0.0.1:1")

def show(result: Net.HttpResult) -> IO(Unit):
  match result:
    case Net.HttpOk{Net.Response{status, body}}:
      IO.print(U32.show(status) ++ ":" ++ body)
    case Net.HttpError{code, message}:
      IO.die(Unit, 1, code ++ ": " ++ message)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    response : Net.HttpResult <- Net.Stiff.send(request(args))
    show(response)
