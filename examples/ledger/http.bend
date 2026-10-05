import Base
import ../../src/contracts.bend as C
import ./engine.bend as E

# Canonical domain operation. JSON decoding and SQLite receipts stay at the edge.
type Operation is Data:
  Operation{key: Nat, expected: Nat, direction: E.Direction, amount: Nat}

type Body is Data:
  Applied{operation: Operation}
  Replayed{operation: Operation}
  Rejected{}

# Both the adapter and laws observe this actual response plan.
def complete(outcome: E.Outcome, operation: Operation) -> C.Decision<E.State, Body>:
  match outcome:
    case E.Outcome{E.Applied{}, state}: C.Decision{state, C.Reply{200n, Applied{operation}}}
    case E.Outcome{E.Replayed{}, state}: C.Decision{state, C.Reply{200n, Replayed{operation}}}
    case E.Outcome{E.Rejected{}, state}: C.Decision{state, C.Reply{422n, Rejected{}}}

def transfer(+state: E.State, +operation: Operation) -> C.Decision<E.State, Body>:
  match operation:
    case Operation{key, expected, direction, amount}:
      complete(E.transfer(state, key, direction, amount), operation)

def transfer_route() -> C.Route:
  C.Route{2n, "POST", "/transfers", False{}, [200n, 400n, 409n, 422n, 500n, 503n]}


def routes() -> List<&2, C.Route>:
  [C.Route{0n, "GET", "/health", False{}, [200n]},
   C.Route{1n, "GET", "/accounts", False{}, [200n, 500n, 503n]},
   transfer_route(),
   C.Route{3n, "GET", "/operations/:id", False{}, [200n, 404n, 409n, 422n, 500n, 503n]},
   C.Route{4n, "GET", "/protected/accounts", True{}, [200n, 401n, 500n, 503n]}]

type Access is Data:
  Execute{id: Nat, params: List<&2, C.Param>}

# A pure dispatch plan. Effects may run only after Execute, never before the guard.
def enter(route: C.Route, params: List<&2, C.Param>, state: Unit) -> C.Decision<Unit, Access>:
  match route:
    case C.Route{id, method, pattern, protected, statuses}:
      C.Decision{state, C.Reply{200n, Execute{id, params}}}

def route(method: String, path: String, valid: Bool) -> C.Decision<Unit, Access>:
  C.dispatch(Unit, Access, routes(), method, path, valid, Unit{}, enter)

