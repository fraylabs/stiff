import Base
import ./deps/stiff/src/contracts.bend as C

def greeting() -> String:
  "hello from @NAME@"

def routes() -> List<&2, C.Route>:
  [C.Route{0n, "GET", "/hello", False{}, [200n]}]

def handle(route: C.Route, params: List<&2, C.Param>, state: Nat) -> C.Decision<Nat, String>:
  C.Decision{state, C.Reply{200n, greeting()}}

def decide(method: String, path: String, state: Nat) -> C.Decision<Nat, String>:
  C.dispatch(Nat, String, routes(), method, path, True{}, state, handle)
