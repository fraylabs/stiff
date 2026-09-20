import Base
import ../../src/http.bend as Http
import ../../src/io.bend as Net

def code(result: Net.HttpResult) -> String:
  match result:
    case Net.HttpError{code, message}: code
    case other: "unexpected response"

def main() -> IO(Unit):
  do IO<Unit>:
    a : Net.HttpResult <- Net.Stiff.send(Http.with_header("X-Bad\0Name", "value", Http.get("http://127.0.0.1:1")))
    b : Net.HttpResult <- Net.Stiff.send(Http.with_header("X-Key", "secret\0suffix", Http.get("http://127.0.0.1:1")))
    IO.print(code(a) ++ ":" ++ code(b))
