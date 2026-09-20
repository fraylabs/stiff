import Base
import ../../src/http.bend as Http

def boolean(value: Bool) -> String:
  match value:
    case True{}: "true"
    case False{}: "false"

def main() -> IO(Unit):
  do IO<Unit>:
    IO.print(boolean(Http.is_success(199)) ++ ":" ++ boolean(Http.is_success(200)) ++ ":" ++ boolean(Http.is_success(299)) ++ ":" ++ boolean(Http.is_success(300)) ++ ":" ++ boolean(Http.is_success(503)))
    IO.print(U32.show(Http.timeout(Http.get("https://example.com"))) ++ ":" ++ U32.show(Http.body_limit(Http.get("https://example.com"))))
