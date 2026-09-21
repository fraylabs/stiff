import Base
import ../../src/url.bend as Url

def show(result: Url.UrlResult) -> IO(Unit):
  match result:
    case Url.UrlReady{text}: IO.print(text)
    case Url.UrlError{code}: IO.print(code)

def main() -> IO(Unit):
  do IO<Unit>:
    IO.bind(Url.UrlResult, Unit, Url.Url.encode_component("\0"), show)
    IO.bind(Url.UrlResult, Unit, Url.Url.encode_component("\u{d800}"), show)
    IO.bind(Url.UrlResult, Unit, Url.Url.encode_component("\u{110000}"), show)
    IO.bind(Url.UrlResult, Unit, Url.Url.with_query("http://example.com/\0", []), show)
    IO.bind(Url.UrlResult, Unit, Url.Url.with_query("http://example.com/", [Url.QueryParam{"bad", "\u{dfff}"}, Url.QueryParam{"unused", "discarded"}]), show)
    IO.bind(Url.UrlResult, Unit, Url.Url.with_query("https://example.com/", [Url.QueryParam{"\0", "\0"}]), show)
    IO.bind(Url.UrlResult, Unit, Url.Url.encode_component("still usable"), show)
