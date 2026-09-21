import Base
import ../../src/http.bend as Http
import ../../src/io.bend as Net

def number(value: Maybe<&2, U32>, fallback: U32) -> U32:
  match value:
    case Some{n}: n
    case None{}: fallback

def request(args: List<String>) -> Http.Request:
  match args:
    case Con{url, Con{method, Con{body, Con{timeout, Con{limit, tail}}}}}:
      Http.Request{method, url, body, number(U32.read(timeout), 10000), number(U32.read(limit), 1048576), Nil{}}
    case other:
      Http.get("http://127.0.0.1:1")

def show(result: Net.HttpResult) -> IO(Unit):
  match result:
    case Net.HttpOk{Net.Response{status, body, headers}}:
      IO.print(U32.show(status) ++ ":" ++ body)
    case Net.HttpError{code, message}:
      IO.die(Unit, 1, code)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    response : Net.HttpResult <- Net.Stiff.send(request(args))
    show(response)
