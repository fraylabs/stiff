import Base
import ../src/app.bend as App
import ../src/router.bend as Router
import ../src/schema.bend as Schema
import ../src/server.bend as Web
import ../src/json.bend as Json
import ./server.bend as Example

def schema() -> Schema.Schema:
  Schema.Object{[
    Schema.Field{"name", True{}, Schema.Text{1n, 40n}},
    Schema.Field{"enabled", True{}, Schema.Boolean{}},
    Schema.Field{"count", True{}, Schema.UInt{1, 100}},
    Schema.Field{"note", False{}, Schema.Nullable{Schema.Text{0n, 100n}}},
    Schema.Field{"tags", False{}, Schema.Sequence{Schema.Text{1n, 12n}, 0n, 4n}},
    Schema.Field{"profile", False{}, Schema.Object{[Schema.Field{"label", True{}, Schema.Text{1n, 20n}}], True{}}}
  ], True{}}

def echo(value: Json.Json) -> IO(Web.Reply):
  Web.json_value(200, value)

def validated(value: Json.Json) -> IO(Web.Reply):
  Schema.apply(schema(), value, echo)

def write(params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, method, path, target, headers, body}: App.json_body(body, validated)

def read_id(value: Maybe<String>) -> IO(Web.Reply):
  match value:
    case Some{id}: Web.json_value(200, Json.object([("id", Json.string(id))]))
    case None{}: App.error(500, "route_error", "Missing route parameter")

def read(params: List<&2, Router.Param>, request: Web.Incoming) -> IO(Web.Reply):
  read_id(Router.param("id", params))

def handler(request: Web.Incoming) -> IO(Web.Reply):
  Router.route([Router.Route{"GET", "/items/:id", read}, Router.Route{"POST", "/items/:id", write}], request)

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
