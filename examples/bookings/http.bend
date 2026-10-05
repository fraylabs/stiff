import Base
import ../../src/contracts.bend as C
import ./model.bend as M
import ./engine.bend as E

type Request is Data:
  Book{key: Nat, room: Nat, start: Nat, end: Nat}
  Cancel{id: Nat}

type Body is Data:
  Snapshot{replayed: Bool}
  Rejected{}

def booking_route() -> C.Route:
  C.Route{1n, "POST", "/bookings", False{}, [200n, 400n, 409n, 422n, 500n, 503n]}

def cancel_route() -> C.Route:
  C.Route{2n, "POST", "/admin/cancellations", True{}, [200n, 400n, 401n, 409n, 422n, 500n, 503n]}

def read_route(method: String) -> C.Route:
  C.Route{0n, method, "/bookings", False{}, [200n, 500n, 503n]}

def routes() -> List<&2, C.Route>:
  [read_route("GET"),
   read_route("HEAD"),
   booking_route(), cancel_route()]

def complete(outcome: M.Outcome) -> C.Decision<M.State, Body>:
  match outcome:
    case M.Outcome{M.Applied{}, state}: C.Decision{state, C.Reply{200n, Snapshot{False{}}}}
    case M.Outcome{M.Replayed{}, state}: C.Decision{state, C.Reply{200n, Snapshot{True{}}}}
    case M.Outcome{M.Rejected{}, state}: C.Decision{state, C.Reply{422n, Rejected{}}}

def handle(route: C.Route, params: List<&2, C.Param>, request: Request, +state: M.State) -> C.Decision<M.State, Body>:
  match route:
    case C.Route{id, method, pattern, protected, statuses}:
      match id:
        case 0n: C.Decision{state, C.Reply{200n, Snapshot{False{}}}}
        case 1n:
          match request:
            case Book{key, room, start, end}: complete(E.book(state, key, room, start, end))
            case other: C.Decision{state, C.Reply{422n, Rejected{}}}
        case 2n:
          match request:
            case Cancel{id}: C.Decision{E.cancel(state, id), C.Reply{200n, Snapshot{False{}}}}
            case other: C.Decision{state, C.Reply{422n, Rejected{}}}
        case other: C.Decision{state, C.Error{500n, "route_error", Nil{}}}

def decide(method: String, path: String, valid: Bool, state: M.State, request: Request) -> C.Decision<M.State, Body>:
  C.dispatch(M.State, Body, routes(), method, path, valid, state, r => ps => s => handle(r, ps, request, s))

type Access is Data:
  Execute{id: Nat}

def enter(route: C.Route, params: List<&2, C.Param>, state: Unit) -> C.Decision<Unit, Access>:
  match route:
    case C.Route{id, method, pattern, protected, statuses}: C.Decision{state, C.Reply{200n, Execute{id}}}

# Authorization/routing before any storage effect.
def route(method: String, path: String, valid: Bool) -> C.Decision<Unit, Access>:
  C.dispatch(Unit, Access, routes(), method, path, valid, Unit{}, enter)
