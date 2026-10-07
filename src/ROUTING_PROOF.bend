import Base
import ./contracts.bend as C
import ./routing_spec.bend as S

# Induction helpers; these are not the independent specification.
def fallback(+verb: String, suffix: C.Selection) -> C.Selection:
  match suffix:
    case C.Found{route, params}: C.Found{route, params}
    case C.Missing{}: C.WrongMethod{[verb]}
    case C.WrongMethod{+methods}: C.WrongMethod{S.retain(S.member(verb, methods), verb, methods)}

# The head wins on exact method equality; otherwise inspect the suffix.
def choose(same: Bool, +route: C.Route, params: List<&2, C.Param>, suffix: C.Selection) -> C.Selection:
  match same:
    case True{}: C.Found{route, params}
    case False{}:
      match route:
        case C.Route{id, verb, pattern, protected, statuses}: fallback(verb, suffix)

def resolve(hits: List<&2, S.Hit>, +method: String) -> C.Selection:
  match hits:
    case Nil{}: C.Missing{}
    case S.Hit{+route, params} <> tail:
      match route:
        case C.Route{id, +verb, pattern, protected, statuses}:
          choose(String.eq(verb, method), route, params, resolve(tail, method))

def fold_select(routes: List<&2, C.Route>, method: String, value: String) -> C.Selection:
  resolve(S.hits(routes, value), method)

law nonempty_matches:
  for +name: String
  for +value: String
  {Bool.and(Bool.not(String.is_empty(name)), Bool.not(String.is_empty(value))) == S.nonempty(name, value) : Bool}
def nonempty_matches(name, value):
  match name value:
    case SNil{} SNil{}: {==}
    case SNil{} SCon{h, t}: {==}
    case SCon{h, t} SNil{}: {==}
    case SCon{h, t} SCon{v, vs}: {==}

law literal_matches:
  for +same: Bool
  for +rest: C.Match
  {C.literal(same, u => rest) == S.combine(S.exact(same), rest) : C.Match}
def literal_matches(same, rest):
  match same:
    case True{}: {==}
    case False{}:
      match rest:
        case C.NoMatch{}: {==}
        case C.Matched{ps}: {==}

law parameter_matches:
  for +ok: Bool
  for +name: String
  for +value: String
  for +rest: C.Match
  {C.literal(ok, u => C.prepend(name, value, rest)) == S.combine(S.parameter(ok, name, value), rest) : C.Match}
def parameter_matches(ok, name, value, rest):
  match ok rest:
    case True{} C.NoMatch{}: {==}
    case True{} C.Matched{ps}: {==}
    case False{} C.NoMatch{}: {==}
    case False{} C.Matched{ps}: {==}

law capture_matches:
  for +parameter: Bool
  for +head: Char
  for +name: String
  for +value: String
  for +rest: C.Match
  {C.capture(parameter, SCon{head, name}, name, value, u => rest)
    == S.combine(S.part_kind(parameter, head, name, value), rest) : C.Match}
def capture_matches(parameter, head, name, value, rest):
  match parameter:
    case False{}: literal_matches(String.eq(SCon{head, name}, value), rest)
    case True{}:
      %Equal.sym(Bool, Bool.and(Bool.not(String.is_empty(name)), Bool.not(String.is_empty(value))), S.nonempty(name, value), nonempty_matches(name, value)) :
        {C.literal(_, u => C.prepend(name, value, rest)) == S.combine(S.parameter(S.nonempty(name, value), name, value), rest) : C.Match}
      parameter_matches(S.nonempty(name, value), name, value, rest)

law segment_matches:
  for +pattern: String
  for +value: String
  for +rest: C.Match
  {C.segment(pattern, value, u => rest) == S.combine(S.part(pattern, value), rest) : C.Match}
def segment_matches(pattern, value, rest):
  match pattern:
    case SNil{}: literal_matches(String.is_empty(value), rest)
    case SCon{head, name}: capture_matches(Char.is_eq(head, ':'), head, name, value, rest)

law values_match_spec:
  for +patterns: List<&2, String>
  for +path: List<&2, String>
  {C.values(patterns, path) == S.segments(patterns, path) : C.Match}
def values_match_spec(patterns, path):
  match patterns path:
    case Nil{} Nil{}: {==}
    case Nil{} v <> vs: {==}
    case p <> ps Nil{}: {==}
    case p <> +ps v <> +vs:
      Equal.trans(C.Match, C.segment(p, v, u => C.values(ps, vs)), S.combine(S.part(p, v), C.values(ps, vs)), S.combine(S.part(p, v), S.segments(ps, vs)),
        segment_matches(p, v, C.values(ps, vs)),
        Equal.cong(C.Match, C.Match, r => S.combine(S.part(p, v), r), C.values(ps, vs), S.segments(ps, vs), values_match_spec(ps, vs)))

law match_path_matches_spec:
  for +pattern: String
  for +path: String
  {C.match_path(pattern, path) == S.path(pattern, path) : C.Match}
def match_path_matches_spec(pattern, path):
  values_match_spec(String.split(pattern, '/'), String.split(path, '/'))

law membership_matches:
  for +verb: String
  for +methods: List<&2, String>
  {C.has_method(verb, methods) == S.member(verb, methods) : Bool}
def membership_matches(verb, methods):
  match methods:
    case Nil{}: {==}
    case m <> +ms:
      Equal.cong(Bool, Bool, b => Bool.or(String.eq(verb, m), b), C.has_method(verb, ms), S.member(verb, ms), membership_matches(verb, ms))

law unique_matches:
  for +duplicate: Bool
  for +verb: String
  for +methods: List<&2, String>
  {C.unique(duplicate, verb, methods) == S.retain(duplicate, verb, methods) : List<&2, String>}
def unique_matches(duplicate, verb, methods):
  match duplicate:
    case True{}: {==}
    case False{}: {==}

law allowed_matches:
  for +verb: String
  for +suffix: C.Selection
  {C.add_allowed(verb, suffix) == fallback(verb, suffix) : C.Selection}
def allowed_matches(verb, suffix):
  match suffix:
    case C.Missing{}: {==}
    case C.Found{route, ps}: {==}
    case C.WrongMethod{+methods}:
      %Equal.sym(Bool, C.has_method(verb, methods), S.member(verb, methods), membership_matches(verb, methods)) :
        {C.WrongMethod{C.unique(_, verb, methods)} == fallback(verb, suffix) : C.Selection}
      Equal.cong(List<&2, String>, C.Selection, ms => C.WrongMethod{ms}, C.unique(S.member(verb, methods), verb, methods), S.retain(S.member(verb, methods), verb, methods), unique_matches(S.member(verb, methods), verb, methods))

law chosen_matches:
  for +same: Bool
  for +route: C.Route
  for +params: List<&2, C.Param>
  for +suffix: C.Selection
  {C.chosen(same, route, params, suffix) == choose(same, route, params, suffix) : C.Selection}
def chosen_matches(same, route, params, suffix):
  match same:
    case True{}: {==}
    case False{}:
      match route:
        case C.Route{id, verb, pattern, protected, statuses}: allowed_matches(verb, suffix)

law selection_step:
  for +result: C.Match
  for +id: Nat
  for +verb: String
  for +pattern: String
  for +protected: Bool
  for +statuses: List<&2, Nat>
  for +method: String
  for +tail: List<&2, S.Hit>
  {C.matched(result, String.eq(verb, method), C.Route{id, verb, pattern, protected, statuses}, resolve(tail, method))
    == resolve(S.include(result, C.Route{id, verb, pattern, protected, statuses}, tail), method) : C.Selection}
def selection_step(result, id, verb, pattern, protected, statuses, method, tail):
  match result:
    case C.NoMatch{}: {==}
    case C.Matched{params}:
      chosen_matches(String.eq(verb, method), C.Route{id, verb, pattern, protected, statuses}, params, resolve(tail, method))

law select_matches_fold:
  for +routes: List<&2, C.Route>
  for +method: String
  for +path: String
  {C.select(routes, method, path) == fold_select(routes, method, path) : C.Selection}
def select_matches_fold(routes, method, path):
  match routes:
    case Nil{}: {==}
    case +route <> +tail:
      match route:
        case C.Route{id, verb, pattern, protected, statuses}:
          %Equal.sym(C.Match, C.match_path(pattern, path), S.path(pattern, path), match_path_matches_spec(pattern, path)) :
            {C.matched(_, String.eq(verb, method), route, C.select(tail, method, path)) == fold_select(route <> tail, method, path) : C.Selection}
          %Equal.sym(C.Selection, C.select(tail, method, path), fold_select(tail, method, path), select_matches_fold(tail, method, path)) :
            {C.matched(S.path(pattern, path), String.eq(verb, method), route, _) == fold_select(route <> tail, method, path) : C.Selection}
          selection_step(S.path(pattern, path), id, verb, pattern, protected, statuses, method, S.hits(tail, path))

law fallback_nonempty:
  for +duplicate: Bool
  for +verb: String
  for +m: String
  for +ms: List<&2, String>
  {C.WrongMethod{S.retain(duplicate, verb, m <> ms)} == S.summary(S.Absent{}, S.retain(duplicate, verb, m <> ms)) : C.Selection}
def fallback_nonempty(duplicate, verb, m, ms):
  match duplicate:
    case True{}: {==}
    case False{}: {==}

law fallback_summary:
  for +verb: String
  for +first: S.First
  for +methods: List<&2, String>
  {fallback(verb, S.summary(first, methods)) == S.summary(first, S.dedup_head(verb, methods)) : C.Selection}
def fallback_summary(verb, first, methods):
  match first:
    case S.Present{S.Hit{route, params}}: {==}
    case S.Absent{}:
      match methods:
        case Nil{}: {==}
        case m <> ms:
          fallback_nonempty(S.member(verb, m <> ms), verb, m, ms)

law choose_summary:
  for +same: Bool
  for +route: C.Route
  for +params: List<&2, C.Param>
  for +first: S.First
  for +methods: List<&2, String>
  {choose(same, route, params, S.summary(first, methods))
    == S.summary(S.first_step(same, S.Hit{route, params}, first), S.dedup_head(S.verb(route), methods)) : C.Selection}
def choose_summary(same, route, params, first, methods):
  match same:
    case True{}: {==}
    case False{}:
      match route:
        case C.Route{id, verb, pattern, protected, statuses}: fallback_summary(verb, first, methods)

law resolve_matches_summary:
  for +hits: List<&2, S.Hit>
  for +method: String
  {resolve(hits, method) == S.summary(S.first(hits, method), S.allowed(hits)) : C.Selection}
def resolve_matches_summary(hits, method):
  match hits:
    case Nil{}: {==}
    case S.Hit{+route, params} <> +tail:
      match route:
        case C.Route{id, verb, pattern, protected, statuses}:
          %Equal.sym(C.Selection, resolve(tail, method), S.summary(S.first(tail, method), S.allowed(tail)), resolve_matches_summary(tail, method)) :
            {choose(String.eq(verb, method), route, params, _) == S.summary(S.first(S.Hit{route, params} <> tail, method), S.allowed(S.Hit{route, params} <> tail)) : C.Selection}
          choose_summary(String.eq(verb, method), route, params, S.first(tail, method), S.allowed(tail))

law select_matches_spec:
  for +routes: List<&2, C.Route>
  for +method: String
  for +path: String
  {C.select(routes, method, path) == S.select(routes, method, path) : C.Selection}
def select_matches_spec(routes, method, path):
  Equal.trans(C.Selection, C.select(routes, method, path), fold_select(routes, method, path), S.select(routes, method, path),
    select_matches_fold(routes, method, path), resolve_matches_summary(S.hits(routes, path), method))

law selected_first:
  for +routes: List<&2, C.Route>
  for +method: String
  for +path: String
  for +route: C.Route
  for +params: List<&2, C.Param>
  for first: {S.first(S.hits(routes, path), method) == S.Present{S.Hit{route, params}} : S.First}
  {C.select(routes, method, path) == C.Found{route, params} : C.Selection}
def selected_first(routes, method, path, route, params, first):
  %Equal.sym(C.Selection, C.select(routes, method, path), S.select(routes, method, path), select_matches_spec(routes, method, path)) :
    {_ == C.Found{route, params} : C.Selection}
  %Equal.sym(S.First, S.first(S.hits(routes, path), method), S.Present{S.Hit{route, params}}, first) :
    {S.summary(_, S.allowed(S.hits(routes, path))) == C.Found{route, params} : C.Selection}
  {==}

law missing_no_hits:
  for +routes: List<&2, C.Route>
  for +method: String
  for +path: String
  for unknown: {S.hits(routes, path) == Nil{} : List<&2, S.Hit>}
  {C.select(routes, method, path) == C.Missing{} : C.Selection}
def missing_no_hits(routes, method, path, unknown):
  Equal.trans(C.Selection, C.select(routes, method, path), S.select(routes, method, path), C.Missing{},
    select_matches_spec(routes, method, path),
    Equal.cong(List<&2, S.Hit>, C.Selection, hs => S.summary(S.first(hs, method), S.allowed(hs)), S.hits(routes, path), Nil{}, unknown))

law known_methods:
  for +verb: String
  for +methods: List<&2, String>
  {S.summary(S.Absent{}, S.dedup_head(verb, methods)) == C.WrongMethod{S.dedup_head(verb, methods)} : C.Selection}
def known_methods(verb, methods):
  match methods:
    case Nil{}: {==}
    case m <> ms:
      Equal.sym(C.Selection, C.WrongMethod{S.dedup_head(verb, m <> ms)}, S.summary(S.Absent{}, S.dedup_head(verb, m <> ms)), fallback_nonempty(S.member(verb, m <> ms), verb, m, ms))

law known_summary:
  for +route: C.Route
  for +params: List<&2, C.Param>
  for +tail: List<&2, S.Hit>
  {S.summary(S.Absent{}, S.allowed(S.Hit{route, params} <> tail))
    == C.WrongMethod{S.allowed(S.Hit{route, params} <> tail)} : C.Selection}
def known_summary(route, params, tail):
  match route:
    case C.Route{id, verb, pattern, protected, statuses}:
      known_methods(verb, S.allowed(tail))

law wrong_method_exact_allow:
  for +routes: List<&2, C.Route>
  for +method: String
  for +path: String
  for +route: C.Route
  for +params: List<&2, C.Param>
  for +tail: List<&2, S.Hit>
  for known: {S.hits(routes, path) == S.Hit{route, params} <> tail : List<&2, S.Hit>}
  for wrong: {S.first(S.Hit{route, params} <> tail, method) == S.Absent{} : S.First}
  {C.select(routes, method, path) == C.WrongMethod{S.allowed(S.Hit{route, params} <> tail)} : C.Selection}
def wrong_method_exact_allow(routes, method, path, route, params, tail, known, wrong):
  %Equal.sym(C.Selection, C.select(routes, method, path), S.select(routes, method, path), select_matches_spec(routes, method, path)) :
    {_ == C.WrongMethod{S.allowed(S.Hit{route, params} <> tail)} : C.Selection}
  %Equal.sym(List<&2, S.Hit>, S.hits(routes, path), S.Hit{route, params} <> tail, known) :
    {S.summary(S.first(_, method), S.allowed(_)) == C.WrongMethod{S.allowed(S.Hit{route, params} <> tail)} : C.Selection}
  %Equal.sym(S.First, S.first(S.Hit{route, params} <> tail, method), S.Absent{}, wrong) :
    {S.summary(_, S.allowed(S.Hit{route, params} <> tail)) == C.WrongMethod{S.allowed(S.Hit{route, params} <> tail)} : C.Selection}
  known_summary(route, params, tail)

law dispatch_unknown:
  for -State: Data
  for -Body: Data
  for +routes: List<&2, C.Route>
  for +method: String
  for +path: String
  for valid: Bool
  for +state: State
  for next: C.Route -> List<&2, C.Param> -> State -> C.Decision<State, Body>
  for unknown: {S.hits(routes, path) == Nil{} : List<&2, S.Hit>}
  {C.dispatch(State, Body, routes, method, path, valid, state, next)
    == C.Decision{state, C.Error{404n, "not_found", Nil{}}} : C.Decision<State, Body>}
def dispatch_unknown(State, Body, routes, method, path, valid, state, next, unknown):
  %Equal.sym(C.Selection, C.select(routes, method, path), C.Missing{}, missing_no_hits(routes, method, path, unknown)) :
    {C.run(State, Body, _, C.readonly(method), valid, state, next) == C.Decision{state, C.Error{404n, "not_found", Nil{}}} : C.Decision<State, Body>}
  {==}

law dispatch_wrong_method:
  for -State: Data
  for -Body: Data
  for +routes: List<&2, C.Route>
  for +method: String
  for +path: String
  for +route: C.Route
  for +params: List<&2, C.Param>
  for +tail: List<&2, S.Hit>
  for valid: Bool
  for +state: State
  for next: C.Route -> List<&2, C.Param> -> State -> C.Decision<State, Body>
  for known: {S.hits(routes, path) == S.Hit{route, params} <> tail : List<&2, S.Hit>}
  for wrong: {S.first(S.Hit{route, params} <> tail, method) == S.Absent{} : S.First}
  {C.dispatch(State, Body, routes, method, path, valid, state, next)
    == C.Decision{state, C.Error{405n, "method_not_allowed", S.allowed(S.Hit{route, params} <> tail)}} : C.Decision<State, Body>}
def dispatch_wrong_method(State, Body, routes, method, path, route, params, tail, valid, state, next, known, wrong):
  %Equal.sym(C.Selection, C.select(routes, method, path), C.WrongMethod{S.allowed(S.Hit{route, params} <> tail)}, wrong_method_exact_allow(routes, method, path, route, params, tail, known, wrong)) :
    {C.run(State, Body, _, C.readonly(method), valid, state, next) == C.Decision{state, C.Error{405n, "method_not_allowed", S.allowed(S.Hit{route, params} <> tail)}} : C.Decision<State, Body>}
  {==}

law dispatch_protected:
  for -State: Data
  for -Body: Data
  for +routes: List<&2, C.Route>
  for +method: String
  for +path: String
  for +id: Nat
  for +verb: String
  for +pattern: String
  for +statuses: List<&2, Nat>
  for +params: List<&2, C.Param>
  for +state: State
  for next: C.Route -> List<&2, C.Param> -> State -> C.Decision<State, Body>
  for first: {S.first(S.hits(routes, path), method) == S.Present{S.Hit{C.Route{id, verb, pattern, True{}, statuses}, params}} : S.First}
  {C.dispatch(State, Body, routes, method, path, False{}, state, next)
    == C.Decision{state, C.Error{401n, "unauthorized", Nil{}}} : C.Decision<State, Body>}
def dispatch_protected(State, Body, routes, method, path, id, verb, pattern, statuses, params, state, next, first):
  %Equal.sym(C.Selection, C.select(routes, method, path), C.Found{C.Route{id, verb, pattern, True{}, statuses}, params}, selected_first(routes, method, path, C.Route{id, verb, pattern, True{}, statuses}, params, first)) :
    {C.run(State, Body, _, C.readonly(method), False{}, state, next) == C.Decision{state, C.Error{401n, "unauthorized", Nil{}}} : C.Decision<State, Body>}
  {==}

law fallback_never_missing:
  for +verb: String
  for suffix: C.Selection
  {S.missing(fallback(verb, suffix)) == False{} : Bool}
def fallback_never_missing(verb, suffix):
  match suffix:
    case C.Found{route, params}: {==}
    case C.Missing{}: {==}
    case C.WrongMethod{methods}: {==}

law choose_never_missing:
  for same: Bool
  for +route: C.Route
  for params: List<&2, C.Param>
  for suffix: C.Selection
  {S.missing(choose(same, route, params, suffix)) == False{} : Bool}
def choose_never_missing(same, route, params, suffix):
  match same:
    case True{}: {==}
    case False{}:
      match route:
        case C.Route{id, verb, pattern, protected, statuses}: fallback_never_missing(verb, suffix)

law resolve_missing_iff:
  for +hits: List<&2, S.Hit>
  for +method: String
  {S.missing(resolve(hits, method)) == S.empty(hits) : Bool}
def resolve_missing_iff(hits, method):
  match hits:
    case Nil{}: {==}
    case S.Hit{+route, params} <> tail:
      match route:
        case C.Route{id, verb, pattern, protected, statuses}:
          choose_never_missing(String.eq(verb, method), route, params, resolve(tail, method))

law missing_iff_no_path:
  for +routes: List<&2, C.Route>
  for +method: String
  for +path: String
  {S.missing(C.select(routes, method, path)) == S.empty(S.hits(routes, path)) : Bool}
def missing_iff_no_path(routes, method, path):
  Equal.trans(Bool, S.missing(C.select(routes, method, path)), S.missing(fold_select(routes, method, path)), S.empty(S.hits(routes, path)),
    Equal.cong(C.Selection, Bool, r => S.missing(r), C.select(routes, method, path), fold_select(routes, method, path), select_matches_fold(routes, method, path)),
    resolve_missing_iff(S.hits(routes, path), method))

law fallback_wrong_summary:
  for +verb: String
  for +first: S.First
  for methods: List<&2, String>
  {S.wrong(fallback(verb, S.summary(first, methods))) == S.absent(first) : Bool}
def fallback_wrong_summary(verb, first, methods):
  match first:
    case S.Present{S.Hit{route, params}}: {==}
    case S.Absent{}:
      match methods:
        case Nil{}: {==}
        case m <> ms: {==}

law choose_wrong_summary:
  for same: Bool
  for +route: C.Route
  for +params: List<&2, C.Param>
  for +first: S.First
  for methods: List<&2, String>
  {S.wrong(choose(same, route, params, S.summary(first, methods))) == S.absent(S.first_step(same, S.Hit{route, params}, first)) : Bool}
def choose_wrong_summary(same, route, params, first, methods):
  match same:
    case True{}: {==}
    case False{}:
      match route:
        case C.Route{id, verb, pattern, protected, statuses}: fallback_wrong_summary(verb, first, methods)

law resolve_wrong_iff:
  for +hits: List<&2, S.Hit>
  for +method: String
  {S.wrong(resolve(hits, method)) == Bool.and(Bool.not(S.empty(hits)), S.absent(S.first(hits, method))) : Bool}
def resolve_wrong_iff(hits, method):
  match hits:
    case Nil{}: {==}
    case S.Hit{+route, params} <> +tail:
      match route:
        case C.Route{id, verb, pattern, protected, statuses}:
          %Equal.sym(C.Selection, resolve(tail, method), S.summary(S.first(tail, method), S.allowed(tail)), resolve_matches_summary(tail, method)) :
            {S.wrong(choose(String.eq(verb, method), route, params, _)) == S.absent(S.first(S.Hit{route, params} <> tail, method)) : Bool}
          choose_wrong_summary(String.eq(verb, method), route, params, S.first(tail, method), S.allowed(tail))

law wrong_method_iff:
  for +routes: List<&2, C.Route>
  for +method: String
  for +path: String
  {S.wrong(C.select(routes, method, path)) == Bool.and(Bool.not(S.empty(S.hits(routes, path))), S.absent(S.first(S.hits(routes, path), method))) : Bool}
def wrong_method_iff(routes, method, path):
  Equal.trans(Bool, S.wrong(C.select(routes, method, path)), S.wrong(fold_select(routes, method, path)), Bool.and(Bool.not(S.empty(S.hits(routes, path))), S.absent(S.first(S.hits(routes, path), method))),
    Equal.cong(C.Selection, Bool, r => S.wrong(r), C.select(routes, method, path), fold_select(routes, method, path), select_matches_fold(routes, method, path)),
    resolve_wrong_iff(S.hits(routes, path), method))
