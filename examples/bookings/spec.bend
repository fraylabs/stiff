import Base
import ./model.bend as M

# Independent observations: half-open intervals, same room only.
def overlap(a: M.Booking, b: M.Booking) -> Bool:
  match a b:
    case M.Booking{ai, ar, ast, ae} M.Booking{bi, br, bst, be}:
      Bool.and(Nat.is_eq(ar, br), Bool.and(Nat.is_lt(ast, be), Nat.is_lt(bst, ae)))

def compatible(+a: M.Booking, bs: List<&2, M.Booking>) -> Bool:
  match bs:
    case Nil{}: True{}
    case b <> tail: Bool.and(Bool.not(overlap(a, b)), compatible(a, tail))

def safe(bs: List<&2, M.Booking>) -> Bool:
  match bs:
    case Nil{}: True{}
    case +b <> +tail: Bool.and(compatible(b, tail), safe(tail))

def state(outcome: M.Outcome) -> M.State:
  match outcome:
    case M.Outcome{status, state}: state

def accepted_safe(outcome: M.Outcome) -> Bool:
  match outcome:
    case M.Outcome{M.Applied{}, M.State{bs, keys}}: safe(bs)
    case M.Outcome{other, state}: True{}

def rejected_state(outcome: M.Outcome, original: M.State) -> M.State:
  match outcome:
    case M.Outcome{M.Rejected{}, state}: state
    case M.Outcome{other, state}: original

def retain(hit: Bool, b: M.Booking, tail: List<&2, M.Booking>) -> List<&2, M.Booking>:
  match hit:
    case True{}: tail
    case False{}: b <> tail

# Remove every occurrence of the named ID, preserving other fields and order.
def without(bs: List<&2, M.Booking>, +id: Nat) -> List<&2, M.Booking>:
  match bs:
    case Nil{}: Nil{}
    case +b <> +tail:
      match b:
        case M.Booking{bid, room, start, end}: retain(Nat.is_eq(bid, id), b, without(tail, id))
