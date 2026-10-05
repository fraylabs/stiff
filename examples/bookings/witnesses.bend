import Base
import ../../src/contracts.bend as C
import ./model.bend as M
import ./engine.bend as E
import ./spec.bend as S
import ./http.bend as H

def writing_read(route: C.Route, params: List<&2, C.Param>, state: M.State) -> C.Decision<M.State, H.Body>:
  C.Decision{M.State{Nil{}, Nil{}}, C.Reply{200n, H.Snapshot{False{}}}}

law half_open_boundary:
  {E.overlap(M.Booking{1n, 0n, 10n, 20n}, M.Booking{2n, 0n, 20n, 30n}) == False{} : Bool}
def half_open_boundary():
  {==}

law enclosing_slot_rejected:
  {E.book(M.State{[M.Booking{1n, 0n, 10n, 20n}], [1n]}, 2n, 0n, 5n, 25n)
    == M.Outcome{M.Rejected{}, M.State{[M.Booking{1n, 0n, 10n, 20n}], [1n]}} : M.Outcome}
def enclosing_slot_rejected():
  {==}

law same_room_rejected:
  {E.book(M.State{[M.Booking{1n, 0n, 10n, 20n}], [1n]}, 2n, 0n, 15n, 25n)
    == M.Outcome{M.Rejected{}, M.State{[M.Booking{1n, 0n, 10n, 20n}], [1n]}} : M.Outcome}
def same_room_rejected():
  {==}

law cancel_exact_instance:
  {E.cancel(M.State{[M.Booking{1n, 0n, 10n, 20n}, M.Booking{2n, 1n, 10n, 20n}], [1n, 2n]}, 1n)
    == M.State{[M.Booking{2n, 1n, 10n, 20n}], [1n, 2n]} : M.State}
def cancel_exact_instance():
  {==}

law retry_once_instance:
  {S.state(E.book(S.state(E.book(E.initial(), 1n, 0n, 10n, 20n)), 1n, 0n, 10n, 20n))
    == S.state(E.book(E.initial(), 1n, 0n, 10n, 20n)) : M.State}
def retry_once_instance():
  {==}

law get_no_write_instance:
  {C.state(M.State, H.Body, C.dispatch(M.State, H.Body, H.routes(), "GET", "/bookings", True{},
      M.State{[M.Booking{1n, 0n, 10n, 20n}], [1n]}, writing_read))
    == M.State{[M.Booking{1n, 0n, 10n, 20n}], [1n]} : M.State}
def get_no_write_instance():
  {==}
