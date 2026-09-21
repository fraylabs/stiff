import Base
import ../src/app.bend as App
import ../src/server.bend as Web
import ../src/json.bend as Json
import ./server.bend as Example

def health(request: Web.Incoming) -> IO(Web.Reply):
  Web.json_value(200, Json.object([("status", Json.string("ok"))]))

def greeting(result: App.TextResult) -> IO(Web.Reply):
  match result:
    case App.TextValid{name}:
      do IO<Web.Reply>:
        IO.print("GREETING")
        Web.json_value(200, Json.object([("greeting", Json.string("Hello, " ++ name))]))
    case App.TextInvalid{field, code}: App.validation_error(field, code)

def validated(value: Json.Json) -> IO(Web.Reply):
  greeting(App.required_text("name", 1n, 40n, value))

def greet(request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, path, target, headers, body}: App.json_body(body, validated)

def routes() -> List<App.Route>:
  [App.Route{"GET", "/health", health}, App.Route{"POST", "/greet", greet}]

def router(request: Web.Incoming) -> IO(Web.Reply):
  App.route(routes(), request)

# A synthetic access gate for middleware demonstration, not an auth system.
def access(value: Maybe<String>) -> Bool:
  match value:
    case Some{text}: String.eq(text, "allowed")
    case None{}: False{}

def gate(request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, path, target, +headers, body}:
      App.guard(access(Web.header("x-demo-access", headers)), 403, "access_denied", "Demo access header required",
        u => router(Web.Incoming{id, method, path, target, headers, body}))

def handler(request: Web.Incoming) -> IO(Web.Reply):
  App.with_header("X-Stiff", "app", gate, request)

def start(result: Web.Started) -> IO(Unit):
  match result:
    case Web.Listening{port}:
      do IO<Unit>:
        IO.print("LISTENING " ++ U32.show(port))
        Web.serve(~handler)
    case Web.ListenError{code}: IO.die(Unit, 1, code)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    result : Web.Started <- Web.Server.listen(Example.config(args))
    start(result)
