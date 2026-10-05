import Base
import ../../src/contracts.bend as C
import ./engine.bend as E
import ./http.bend as H

# The response has the replay tag and retains the supplied ORIGINAL operation.
law replay_response:
  for +state: E.State
  for +original: H.Operation
  for key: Nat
  for direction: E.Direction
  for amount: Nat
  {H.complete(E.dispatch(True{}, state, key, direction, amount), original)
    == C.Decision{state, C.Reply{200n, H.Replayed{original}}} : C.Decision<E.State, H.Body>}
def replay_response(state, original, key, direction, amount):
  {==}

law transfer_status_declared:
  for outcome: E.Outcome
  for operation: H.Operation
  {C.declared(H.Body, H.transfer_route(), C.response(E.State, H.Body, H.complete(outcome, operation)))
    == True{} : Bool}
def transfer_status_declared(outcome, operation):
  match outcome:
    case E.Outcome{status, state}:
      match status:
        case E.Applied{}: {==}
        case E.Replayed{}: {==}
        case E.Rejected{}: {==}

law protected_accounts_denied:
  {H.route("GET", "/protected/accounts", False{})
    == C.Decision{Unit{}, C.Error{401n, "unauthorized", Nil{}}} : C.Decision<Unit, H.Access>}
def protected_accounts_denied():
  {==}

law unknown_route:
  {H.route("GET", "/absent", True{})
    == C.Decision{Unit{}, C.Error{404n, "not_found", Nil{}}} : C.Decision<Unit, H.Access>}
def unknown_route():
  {==}

law wrong_method_allow:
  {H.route("DELETE", "/transfers", True{})
    == C.Decision{Unit{}, C.Error{405n, "method_not_allowed", ["POST"]}} : C.Decision<Unit, H.Access>}
def wrong_method_allow():
  {==}

# Malicious read handler proposes a debit. The framework must discard it.
def writing_read(route: C.Route, params: List<&2, C.Param>, state: E.State) -> C.Decision<E.State, H.Body>:
  C.Decision{E.State{0n, 0n, Nil{}}, C.Reply{200n, H.Rejected{}}}

law get_does_not_write:
  for +state: E.State
  {C.state(E.State, H.Body, C.dispatch(E.State, H.Body, H.routes(), "GET", "/accounts", True{}, state, writing_read))
    == state : E.State}
def get_does_not_write(state):
  {==}

law head_does_not_write:
  for +state: E.State
  {C.state(E.State, H.Body, C.dispatch(E.State, H.Body,
      [C.Route{1n, "HEAD", "/accounts", False{}, [200n]}], "HEAD", "/accounts", True{}, state, writing_read))
    == state : E.State}
def head_does_not_write(state):
  {==}

