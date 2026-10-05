import Base
import ./engine.bend as E
import ./spec.bend as S
import ./http.bend as H
import ../../src/contracts.bend as C

law replay_response_example:
  {H.complete(E.dispatch(True{}, E.State{10n, 10n, [7n]}, 7n, E.AliceToBob{}, 2n),
      H.Operation{7n, 1n, E.AliceToBob{}, 2n})
    == C.Decision{E.State{10n, 10n, [7n]}, C.Reply{200n, H.Replayed{H.Operation{7n, 1n, E.AliceToBob{}, 2n}}}}
    : C.Decision<E.State, H.Body>}
def replay_response_example():
  {==}

law protected_accounts_example:
  {H.route("GET", "/protected/accounts", False{})
    == C.Decision{Unit{}, C.Error{401n, "unauthorized", Nil{}}} : C.Decision<Unit, H.Access>}
def protected_accounts_example():
  {==}

def writing_read(route: C.Route, params: List<&2, C.Param>, state: E.State) -> C.Decision<E.State, H.Body>:
  C.Decision{E.State{0n, 0n, Nil{}}, C.Reply{200n, H.Rejected{}}}

law get_no_write_example:
  {C.state(E.State, H.Body, C.dispatch(E.State, H.Body, H.routes(), "GET", "/accounts", True{},
      E.State{10n, 10n, [7n]}, writing_read)) == E.State{10n, 10n, [7n]} : E.State}
def get_no_write_example():
  {==}

law declared_status_example:
  {C.declared(H.Body, H.transfer_route(), C.response(E.State, H.Body,
      H.complete(E.Outcome{E.Applied{}, E.State{8n, 12n, [7n]}}, H.Operation{7n, 1n, E.AliceToBob{}, 2n})))
    == True{} : Bool}
def declared_status_example():
  {==}

