import Base
import ./contracts.bend as C

law protected_denies:
  for -S: Data
  for -B: Data
  for +state: S
  for next: S -> C.Decision<S, B>
  {C.authorize(S, B, True{}, False{}, state, next)
    == C.Decision{state, C.Error{401n, "unauthorized", Nil{}}} : C.Decision<S, B>}
def protected_denies(S, B, state, next):
  {==}

law read_preserves:
  for -S: Data
  for -B: Data
  for +state: S
  for proposed: C.Decision<S, B>
  {C.state(S, B, C.preserve(S, B, True{}, state, proposed)) == state : S}
def read_preserves(S, B, state, proposed):
  match proposed:
    case C.Decision{changed, response}: {==}

law dispatch_read_preserves:
  for -S: Data
  for -B: Data
  for selection: C.Selection
  for valid: Bool
  for +state: S
  for next: C.Route -> List<&2, C.Param> -> S -> C.Decision<S, B>
  {C.state(S, B, C.run(S, B, selection, True{}, valid, state, next)) == state : S}
def dispatch_read_preserves(S, B, selection, valid, state, next):
  match selection:
    case C.Missing{}: {==}
    case C.WrongMethod{methods}: {==}
    case C.Found{+route, params}:
      match route:
        case C.Route{id, method, pattern, protected, statuses}:
          match protected valid:
            case True{} False{}: {==}
            case True{} True{}: read_preserves(S, B, state, next(route, params, state))
            case False{} True{}: read_preserves(S, B, state, next(route, params, state))
            case False{} False{}: read_preserves(S, B, state, next(route, params, state))

law get_is_read:
  {C.readonly("GET") == True{} : Bool}
def get_is_read():
  {==}

law head_is_read:
  {C.readonly("HEAD") == True{} : Bool}
def head_is_read():
  {==}

law unknown_is_404:
  for -S: Data
  for -B: Data
  for read: Bool
  for valid: Bool
  for +state: S
  for next: C.Route -> List<&2, C.Param> -> S -> C.Decision<S, B>
  {C.run(S, B, C.Missing{}, read, valid, state, next)
    == C.Decision{state, C.Error{404n, "not_found", Nil{}}} : C.Decision<S, B>}
def unknown_is_404(S, B, read, valid, state, next):
  {==}

law wrong_method_is_405:
  for -S: Data
  for -B: Data
  for +methods: List<&2, String>
  for read: Bool
  for valid: Bool
  for +state: S
  for next: C.Route -> List<&2, C.Param> -> S -> C.Decision<S, B>
  {C.run(S, B, C.WrongMethod{methods}, read, valid, state, next)
    == C.Decision{state, C.Error{405n, "method_not_allowed", methods}} : C.Decision<S, B>}
def wrong_method_is_405(S, B, methods, read, valid, state, next):
  {==}

law protected_route_denies:
  for -S: Data
  for -B: Data
  for id: Nat
  for method: String
  for pattern: String
  for statuses: List<&2, Nat>
  for params: List<&2, C.Param>
  for read: Bool
  for +state: S
  for next: C.Route -> List<&2, C.Param> -> S -> C.Decision<S, B>
  {C.run(S, B, C.Found{C.Route{id, method, pattern, True{}, statuses}, params}, read, False{}, state, next)
    == C.Decision{state, C.Error{401n, "unauthorized", Nil{}}} : C.Decision<S, B>}
def protected_route_denies(S, B, id, method, pattern, statuses, params, read, state, next):
  {==}
