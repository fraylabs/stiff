import Base
import ../../src/app.bend as App
import ../../src/server.bend as Web

def first(request: Web.Incoming) -> IO(Web.Reply):
  IO.pure(Web.Reply, Web.json(200, "first"))

def second(request: Web.Incoming) -> IO(Web.Reply):
  IO.pure(Web.Reply, Web.json(200, "second"))

def routes() -> List<App.Route>:
  [App.Route{"GET", "/a", first}, App.Route{"GET", "/a", second},
   App.Route{"POST", "/a", second}, App.Route{"GET", "/else", second}]

def body(reply: Web.Reply) -> IO(Unit):
  match reply:
    case Web.Reply{status, headers, text}: IO.print(text)

def show(selection: App.Selection) -> IO(Unit):
  match selection:
    case App.Found{handler}:
      IO.bind(Web.Reply, Unit, handler(Web.Incoming{0, "GET", "/a", "/a", Nil{}, ""}), body)
    case App.Missing{}: IO.print("missing")
    case App.WrongMethod{methods}: IO.print(App.allowed(methods))

def main() -> IO(Unit):
  do IO<Unit>:
    show(App.select(routes(), "GET", "/a"))
    show(App.select(routes(), "DELETE", "/a"))
    show(App.select(routes(), "GET", "/absent"))
    show(App.select(routes(), "POST", "/a"))
