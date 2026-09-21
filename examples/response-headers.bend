import Base
import ../src/http.bend as Http
import ../src/io.bend as Net

def optional(value: Maybe<String>) -> String:
  match value:
    case Some{text}: text
    case None{}: "(absent)"

def print_cookies(values: List<String>) -> IO(Unit):
  match values:
    case Nil{}: IO.pure(Unit, Unit{})
    case Con{value, tail}:
      do IO<Unit>:
        IO.print("set-cookie:" ++ value)
        print_cookies(tail)

def print_headers(headers: List<&2, Net.ResponseHeader>) -> IO(Unit):
  match headers:
    case Nil{}: IO.pure(Unit, Unit{})
    case Con{Net.ResponseHeader{name, value}, tail}:
      do IO<Unit>:
        IO.print(name ++ ":" ++ value)
        print_headers(tail)

def show(result: Net.HttpResult) -> IO(Unit):
  match result:
    case Net.HttpOk{Net.Response{status, body, +headers}}:
      do IO<Unit>:
        IO.print(U32.show(status) ++ ":" ++ body)
        IO.print("etag-first:" ++ optional(Net.header("etag", headers)))
        IO.print("missing:" ++ optional(Net.header("x-missing", headers)))
        print_cookies(Net.header_values("set-cookie", headers))
        print_headers(headers)
    case Net.HttpError{code, message}:
      IO.die(Unit, 1, code)

def run(args: List<String>) -> IO(Unit):
  match args:
    case Con{url, Con{method, Nil{}}}:
      do IO<Unit>:
        result : Net.HttpResult <- Net.Stiff.send(Http.Request{method, url, "", 2000, 1048576, Nil{}})
        show(result)
    case other:
      IO.die(Unit, 1, "Usage: response-headers URL GET|HEAD")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
