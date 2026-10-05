import Base

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


def has_method(+name: String, names: List<&2, String>) -> Bool:
  match names:
    case Nil{}: False{}
    case head <> tail: Bool.or(String.eq(name, head), has_method(name, tail))

def unique(found: Bool, name: String, names: List<&2, String>) -> List<&2, String>:
  match found:
    case True{}: names
    case False{}: name <> names

# Metadata is data, not an effectful handler registry. IDs are application-owned.
type Route is Data:
  Route{id: Nat, method: String, pattern: String, protected: Bool, statuses: List<&2, Nat>}

type Selection is Data:
  Found{route: Route, params: List<&2, Param>}
  Missing{}
  WrongMethod{methods: List<&2, String>}

type Response<-B: Data> is Data:
  Reply{status: Nat, body: B}
  Error{status: Nat, code: String, allow: List<&2, String>}

type Decision<-S: Data, -B: Data> is Data:
  Decision{state: S, response: Response<B>}

def add_allowed(+method: String, result: Selection) -> Selection:
  match result:
    case Found{route, params}: Found{route, params}
    case Missing{}: WrongMethod{[method]}
    case WrongMethod{+methods}: WrongMethod{unique(has_method(method, methods), method, methods)}

def chosen(same: Bool, +route: Route, params: List<&2, Param>, rest: Selection) -> Selection:
  match same:
    case True{}: Found{route, params}
    case False{}:
      match route:
        case Route{id, method, pattern, protected, statuses}: add_allowed(method, rest)

def matched(result: Match, same: Bool, route: Route, rest: Selection) -> Selection:
  match result:
    case Matched{params}: chosen(same, route, params, rest)
    case NoMatch{}: rest

def select(routes: List<&2, Route>, +method: String, +path: String) -> Selection:
  match routes:
    case Nil{}: Missing{}
    case +route <> tail:
      match route:
        case Route{id, +verb, pattern, protected, statuses}:
          matched(match_path(pattern, path), String.eq(verb, method), route, select(tail, method, path))

def readonly(+method: String) -> Bool:
  Bool.or(String.eq(method, "GET"), String.eq(method, "HEAD"))

# Restore the complete modeled state for reads. There are no effects to undo.
def preserve(-S: Data, -B: Data, read: Bool, original: S, proposed: Decision<S, B>) -> Decision<S, B>:
  match read:
    case True{}:
      match proposed:
        case Decision{state, response}: Decision{original, response}
    case False{}: proposed

# The guard receives a pure continuation, never IO. Denial cannot execute it.
def authorize(-S: Data, -B: Data, protected: Bool, valid: Bool, +state: S, next: S -> Decision<S, B>) -> Decision<S, B>:
  match protected valid:
    case True{} False{}: Decision{state, Error{401n, "unauthorized", Nil{}}}
    case other other_valid: next(state)

def run(-S: Data, -B: Data, selection: Selection, read: Bool, valid: Bool, +state: S,
    next: Route -> List<&2, Param> -> S -> Decision<S, B>) -> Decision<S, B>:
  match selection:
    case Missing{}: Decision{state, Error{404n, "not_found", Nil{}}}
    case WrongMethod{methods}: Decision{state, Error{405n, "method_not_allowed", methods}}
    case Found{+route, params}:
      match route:
        case Route{id, method, pattern, protected, statuses}:
          authorize(S, B, protected, valid, state, +s => preserve(S, B, read, s, next(route, params, s)))

def dispatch(-S: Data, -B: Data, routes: List<&2, Route>, +method: String, path: String,
    valid: Bool, state: S, next: Route -> List<&2, Param> -> S -> Decision<S, B>) -> Decision<S, B>:
  run(S, B, select(routes, method, path), readonly(method), valid, state, next)

def state(-S: Data, -B: Data, decision: Decision<S, B>) -> S:
  match decision:
    case Decision{state, response}: state

def response(-S: Data, -B: Data, decision: Decision<S, B>) -> Response<B>:
  match decision:
    case Decision{state, response}: response

def status(-B: Data, response: Response<B>) -> Nat:
  match response:
    case Reply{status, body}: status
    case Error{status, code, allow}: status

def contains(statuses: List<&2, Nat>, +status: Nat) -> Bool:
  match statuses:
    case Nil{}: False{}
    case head <> tail: Bool.or(Nat.is_eq(head, status), contains(tail, status))

# Declare 401 on protected routes; 404/405 belong to the router, not a handler.
# This observation does not repair a wrong status: prove it True in app laws.
def declared(-B: Data, route: Route, response: Response<B>) -> Bool:
  match route:
    case Route{id, method, pattern, protected, statuses}: contains(statuses, status(B, response))
