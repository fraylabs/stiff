import Base
import ../../src/contracts.bend as C
import ../../src/CONTRACTS_PROOF.bend as CP
import ./model.bend as M
import ./http.bend as H
import ./engine.bend as E

law booking_status_declared:
  for outcome: M.Outcome
  {C.declared(H.Body, H.booking_route(), C.response(M.State, H.Body, H.complete(outcome))) == True{} : Bool}
def booking_status_declared(outcome):
  match outcome:
    case M.Outcome{status, state}:
      match status:
        case M.Applied{}: {==}
        case M.Replayed{}: {==}
        case M.Rejected{}: {==}

law cancellation_status_declared:
  for state: M.State
  for request: H.Request
  {C.declared(H.Body, H.cancel_route(), C.response(M.State, H.Body, H.handle(H.cancel_route(), Nil{}, request, state))) == True{} : Bool}
def cancellation_status_declared(state, request):
  match request:
    case H.Book{key, room, start, end}: {==}
    case H.Cancel{id}: {==}

law read_status_declared:
  for state: M.State
  for request: H.Request
  {C.declared(H.Body, H.read_route("GET"),
    C.response(M.State, H.Body, H.handle(H.read_route("GET"), Nil{}, request, state))) == True{} : Bool}
def read_status_declared(state, request):
  {==}

law admin_denied:
  for +state: M.State
  for request: H.Request
  {H.decide("POST", "/admin/cancellations", False{}, state, request)
    == C.Decision{state, C.Error{401n, "unauthorized", Nil{}}} : C.Decision<M.State, H.Body>}
def admin_denied(state, request):
  {==}

law access_denied_before_effects:
  {H.route("POST", "/admin/cancellations", False{})
    == C.Decision{Unit{}, C.Error{401n, "unauthorized", Nil{}}} : C.Decision<Unit, H.Access>}
def access_denied_before_effects():
  {==}

# These quantify over ANY pure handler, including one proposing a write.
law get_does_not_write:
  for +state: M.State
  for next: C.Route -> List<&2, C.Param> -> M.State -> C.Decision<M.State, H.Body>
  {C.state(M.State, H.Body, C.dispatch(M.State, H.Body, H.routes(), "GET", "/bookings", True{}, state, next)) == state : M.State}
def get_does_not_write(state, next):
  CP.dispatch_read_preserves(M.State, H.Body, C.select(H.routes(), "GET", "/bookings"), True{}, state, next)

law head_does_not_write:
  for +state: M.State
  for next: C.Route -> List<&2, C.Param> -> M.State -> C.Decision<M.State, H.Body>
  {C.state(M.State, H.Body, C.dispatch(M.State, H.Body, H.routes(), "HEAD", "/bookings", True{}, state, next)) == state : M.State}
def head_does_not_write(state, next):
  CP.dispatch_read_preserves(M.State, H.Body, C.select(H.routes(), "HEAD", "/bookings"), True{}, state, next)

law unknown_route:
  {H.route("GET", "/absent", True{}) == C.Decision{Unit{}, C.Error{404n, "not_found", Nil{}}} : C.Decision<Unit, H.Access>}
def unknown_route():
  {==}

law wrong_method:
  {H.route("DELETE", "/bookings", True{}) == C.Decision{Unit{}, C.Error{405n, "method_not_allowed", ["GET", "HEAD", "POST"]}} : C.Decision<Unit, H.Access>}
def wrong_method():
  {==}

law booking_handler_status_declared:
  for +state: M.State
  for request: H.Request
  {C.declared(H.Body, H.booking_route(), C.response(M.State, H.Body, H.handle(H.booking_route(), Nil{}, request, state))) == True{} : Bool}
def booking_handler_status_declared(state, request):
  match request:
    case H.Book{key, room, start, end}: booking_status_declared(E.book(state, key, room, start, end))
    case H.Cancel{id}: {==}

law admin_response_status_declared:
  for valid: Bool
  for state: M.State
  for request: H.Request
  {C.declared(H.Body, H.cancel_route(), C.response(M.State, H.Body, H.decide("POST", "/admin/cancellations", valid, state, request))) == True{} : Bool}
def admin_response_status_declared(valid, state, request):
  match valid:
    case False{}: {==}
    case True{}: cancellation_status_declared(state, request)

law head_status_declared:
  for state: M.State
  for request: H.Request
  {C.declared(H.Body, H.read_route("HEAD"),
    C.response(M.State, H.Body, H.decide("HEAD", "/bookings", True{}, state, request))) == True{} : Bool}
def head_status_declared(state, request):
  {==}
