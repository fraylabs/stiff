import Base
import ./server.bend as Web
import ./app.bend as App

type Param is Data:
  Param{name: String, value: String}

type Match is Data:
  Matched{params: List<&2, Param>}
  NoMatch{}

def prepend(name: String, value: String, result: Match) -> Match:
  match result:
    case Matched{params}: Matched{Param{name, value} <> params}
    case NoMatch{}: NoMatch{}

def literal(same: Bool, next: Unit -> Match) -> Match:
  match same:
    case True{}: next(Unit{})
    case False{}: NoMatch{}

def capture(parameter: Bool, pattern: String, +name: String, +value: String, next: Unit -> Match) -> Match:
  match parameter:
    case True{}:
      literal(Bool.and(Bool.not(String.is_empty(name)), Bool.not(String.is_empty(value))), u => prepend(name, value, next(Unit{})))
    case False{}: literal(String.eq(pattern, value), next)

def segment(pattern: String, +value: String, next: Unit -> Match) -> Match:
  match pattern:
    case SNil{}: literal(String.is_empty(value), next)
    case SCon{+head, +tail}:
      capture(Char.is_eq(head, ':'), SCon{head, tail}, tail, value, next)

def values(patterns: List<&2, String>, path: List<&2, String>) -> Match:
  match patterns path:
    case Nil{} Nil{}: Matched{Nil{}}
    case Con{pattern, tail} Con{head, rest}: segment(pattern, head, u => values(tail, rest))
    case other other_path: NoMatch{}

def match_path(pattern: String, path: String) -> Match:
  values(String.split(pattern, '/'), String.split(path, '/'))

def param_step(found: Bool, value: String, next: Unit -> Maybe<String>) -> Maybe<String>:
  match found:
    case True{}: Some{value}
    case False{}: next(Unit{})

def param(+name: String, params: List<&2, Param>) -> Maybe<String>:
  match params:
    case Nil{}: None{}
    case Con{Param{key, value}, tail}: param_step(String.eq(name, key), value, u => param(name, tail))

type Route is Type:
  Route{method: String, pattern: String, handler: List<&2, Param> -> Web.Incoming -> IO(Web.Reply)}

type Selection is Type:
  Found{params: List<&2, Param>, handler: List<&2, Param> -> Web.Incoming -> IO(Web.Reply)}
  Missing{}
  WrongMethod{methods: List<&2, String>}

def add_allowed(+method: String, result: Selection) -> Selection:
  match result:
    case Found{params, handler}: Found{params, handler}
    case Missing{}: WrongMethod{[method]}
    case WrongMethod{+methods}: WrongMethod{App.unique(App.contains(method, methods), method, methods)}

def chosen(same: Bool, method: String, params: List<&2, Param>, handler: List<&2, Param> -> Web.Incoming -> IO(Web.Reply), next: Unit -> Selection) -> Selection:
  match same:
    case True{}: Found{params, handler}
    case False{}: add_allowed(method, next(Unit{}))

def matched(result: Match, same: Bool, method: String, handler: List<&2, Param> -> Web.Incoming -> IO(Web.Reply), next: Unit -> Selection) -> Selection:
  match result:
    case Matched{params}: chosen(same, method, params, handler, next)
    case NoMatch{}: next(Unit{})

def select(routes: List<Route>, +method: String, +path: String) -> Selection:
  match routes:
    case Nil{}: Missing{}
    case Con{Route{+verb, pattern, handler}, tail}:
      matched(match_path(pattern, path), String.eq(verb, method), verb, handler, u => select(tail, method, path))

def selected(result: Selection, request: Web.Incoming) -> IO(Web.Reply):
  match result:
    case Found{params, handler}: handler(params, request)
    case Missing{}: App.error(404, "not_found", "No route matches this path")
    case WrongMethod{methods}:
      do IO<Web.Reply>:
        reply : Web.Reply <- App.error(405, "method_not_allowed", "Method not allowed for this path")
        IO.pure(Web.Reply, Web.with_header("Allow", App.allowed(methods), reply))

def route(routes: List<Route>, request: Web.Incoming) -> IO(Web.Reply):
  match request:
    case Web.Incoming{id, +method, +path, target, headers, body}:
      selected(select(routes, method, path), Web.Incoming{id, method, path, target, headers, body})
