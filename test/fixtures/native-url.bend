import Base
import ../../src/url.bend as Url

def params(args: List<String>) -> List<&2, Url.QueryParam>:
  match args:
    case Con{name, Con{value, tail}}: Con{Url.QueryParam{name, value}, params(tail)}
    case other: Nil{}

def show(result: Url.UrlResult) -> IO(Unit):
  match result:
    case Url.UrlReady{text}: IO.print(text)
    case Url.UrlError{code}: IO.die(Unit, 1, code)

def run(args: List<String>) -> IO(Unit):
  match args:
    case Con{value, Nil{}}:
      IO.bind(Url.UrlResult, Unit, Url.Url.encode_component(value), show)
    case Con{base, Con{mode, rest}}:
      IO.bind(Url.UrlResult, Unit, Url.Url.with_query(base, params(rest)), show)
    case other:
      IO.die(Unit, 1, "Expected text or base query [name value ...]")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
