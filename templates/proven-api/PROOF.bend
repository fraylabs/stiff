import Base
import ./deps/stiff/src/contracts.bend as C
import ./api.bend as Api

# An arbitrary input state, exact status, exact body, and unchanged full state.
law hello_contract:
  for +state: Nat
  {Api.decide("GET", "/hello", state)
    == C.Decision{state, C.Reply{200n, "hello from @NAME@"}} : C.Decision<Nat, String>}
def hello_contract(state):
  {==}
