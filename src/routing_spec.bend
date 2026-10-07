import Base
import ./contracts.bend as C

# Independent pure specification; no implementation matching/selection helpers.
def combine(first: C.Match, rest: C.Match) -> C.Match:
  match first rest:
    case C.Matched{Nil{}} other: other
    case C.Matched{Con{p, Nil{}}} C.Matched{ps}: C.Matched{p <> ps}
    case other other_rest: C.NoMatch{}

def exact(same: Bool) -> C.Match:
  match same:
    case True{}: C.Matched{Nil{}}
    case False{}: C.NoMatch{}

def parameter(ok: Bool, name: String, value: String) -> C.Match:
  match ok:
    case True{}: C.Matched{[C.Param{name, value}]}
    case False{}: C.NoMatch{}

def nonempty(name: String, value: String) -> Bool:
  match name value:
    case SCon{h, t} SCon{v, vs}: True{}
    case other other_value: False{}

def part_kind(is_parameter: Bool, head: Char, +name: String, +value: String) -> C.Match:
  match is_parameter:
    case True{}: parameter(nonempty(name, value), name, value)
    case False{}: exact(String.eq(SCon{head, name}, value))

def part(pattern: String, +value: String) -> C.Match:
  match pattern:
    case SNil{}: exact(String.is_empty(value))
    case SCon{+head, +name}:
      part_kind(Char.is_eq(head, ':'), head, name, value)

def segments(pattern: List<&2, String>, path: List<&2, String>) -> C.Match:
  match pattern path:
    case Nil{} Nil{}: C.Matched{Nil{}}
    case p <> ps v <> vs: combine(part(p, v), segments(ps, vs))
    case other other_path: C.NoMatch{}

def path(pattern: String, value: String) -> C.Match:
  segments(String.split(pattern, '/'), String.split(value, '/'))

# Filter path matches, retaining table order and exact captured parameters.
type Hit is Data:
  Hit{route: C.Route, params: List<&2, C.Param>}

def include(result: C.Match, route: C.Route, tail: List<&2, Hit>) -> List<&2, Hit>:
  match result:
    case C.NoMatch{}: tail
    case C.Matched{params}: Hit{route, params} <> tail

def hits(routes: List<&2, C.Route>, +value: String) -> List<&2, Hit>:
  match routes:
    case Nil{}: Nil{}
    case +route <> tail:
      match route:
        case C.Route{id, method, pattern, protected, statuses}:
          include(path(pattern, value), route, hits(tail, value))

# Keep the last occurrence of each verb, without changing suffix order.
def member(+verb: String, methods: List<&2, String>) -> Bool:
  match methods:
    case Nil{}: False{}
    case m <> ms: Bool.or(String.eq(verb, m), member(verb, ms))

def retain(duplicate: Bool, verb: String, methods: List<&2, String>) -> List<&2, String>:
  match duplicate:
    case True{}: methods
    case False{}: verb <> methods

# Two separate observations define the public specification: the first method
# hit, and all path-hit methods deduplicated by their last occurrence.
type First is Data:
  Present{hit: Hit}
  Absent{}

def first_step(same: Bool, hit: Hit, suffix: First) -> First:
  match same:
    case True{}: Present{hit}
    case False{}: suffix

def first(hits: List<&2, Hit>, +method: String) -> First:
  match hits:
    case Nil{}: Absent{}
    case +hit <> tail:
      match hit:
        case Hit{C.Route{id, verb, pattern, protected, statuses}, params}:
          first_step(String.eq(verb, method), hit, first(tail, method))

def dedup_head(+verb: String, +suffix: List<&2, String>) -> List<&2, String>:
  retain(member(verb, suffix), verb, suffix)

def verb(route: C.Route) -> String:
  match route:
    case C.Route{id, method, pattern, protected, statuses}: method

def allowed(hits: List<&2, Hit>) -> List<&2, String>:
  match hits:
    case Nil{}: Nil{}
    case Hit{C.Route{id, +verb, pattern, protected, statuses}, params} <> tail:
      dedup_head(verb, allowed(tail))

def summary(first: First, methods: List<&2, String>) -> C.Selection:
  match first:
    case Present{Hit{route, params}}: C.Found{route, params}
    case Absent{}:
      match methods:
        case Nil{}: C.Missing{}
        case m <> ms: C.WrongMethod{m <> ms}

def select(+routes: List<&2, C.Route>, +method: String, +value: String) -> C.Selection:
  summary(first(hits(routes, value), method), allowed(hits(routes, value)))

def empty(hits: List<&2, Hit>) -> Bool:
  match hits:
    case Nil{}: True{}
    case h <> hs: False{}

def absent(first: First) -> Bool:
  match first:
    case Absent{}: True{}
    case Present{hit}: False{}

def missing(selection: C.Selection) -> Bool:
  match selection:
    case C.Missing{}: True{}
    case C.Found{route, params}: False{}
    case C.WrongMethod{methods}: False{}

def wrong(selection: C.Selection) -> Bool:
  match selection:
    case C.Missing{}: False{}
    case C.Found{route, params}: False{}
    case C.WrongMethod{methods}: True{}
