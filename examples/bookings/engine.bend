import Base
import ./model.bend as M

# Checked against independent observations in spec.bend.
def overlap(a: M.Booking, b: M.Booking) -> Bool:
  match a b:
    case M.Booking{ai, ar, +ast, ae} M.Booking{bi, br, bst, be}:
      Bool.and(Nat.is_eq(ar, br), Bool.and(Nat.is_lt(ast, be), Nat.is_lt(bst, ae)))

def compatible(+a: M.Booking, bs: List<&2, M.Booking>) -> Bool:
  match bs:
    case Nil{}: True{}
    case b <> tail: Bool.and(Bool.not(overlap(a, b)), compatible(a, tail))

def safe(bs: List<&2, M.Booking>) -> Bool:
  match bs:
    case Nil{}: True{}
    case +b <> +tail: Bool.and(compatible(b, tail), safe(tail))

def seen(keys: List<&2, Nat>, +key: Nat) -> Bool:
  match keys:
    case Nil{}: False{}
    case head <> tail: Bool.or(Nat.is_eq(head, key), seen(tail, key))

def valid(b: M.Booking) -> Bool:
  match b:
    case M.Booking{id, room, start, end}:
      Bool.and(Nat.is_lt(room, 3n), Nat.is_lt(start, end))

# Validate the whole candidate, including pre-existing conflicts in arbitrary states.
def finish(ok: Bool, +original: M.State, key: Nat, b: M.Booking) -> M.Outcome:
  match ok:
    case False{}: M.Outcome{M.Rejected{}, original}
    case True{}:
      match original:
        case M.State{bs, keys}: M.Outcome{M.Applied{}, M.State{b <> bs, key <> keys}}

def checked(valid: Bool, +original: M.State, key: Nat, +b: M.Booking) -> M.Outcome:
  match valid:
    case False{}: M.Outcome{M.Rejected{}, original}
    case True{}:
      match original:
        case M.State{bs, keys}: finish(safe(b <> bs), original, key, b)

def dispatch(duplicate: Bool, +original: M.State, key: Nat, +b: M.Booking) -> M.Outcome:
  match duplicate:
    case True{}: M.Outcome{M.Replayed{}, original}
    case False{}: checked(valid(b), original, key, b)

# Booking ID is its idempotency key; fresh keys give distinct IDs.
def book(+original: M.State, +key: Nat, room: Nat, start: Nat, end: Nat) -> M.Outcome:
  match original:
    case M.State{bs, keys}: dispatch(seen(keys, key), original, key, M.Booking{key, room, start, end})

def keep(hit: Bool, b: M.Booking, tail: List<&2, M.Booking>) -> List<&2, M.Booking>:
  match hit:
    case True{}: tail
    case False{}: b <> tail

def remove(bs: List<&2, M.Booking>, +id: Nat) -> List<&2, M.Booking>:
  match bs:
    case Nil{}: Nil{}
    case +b <> +tail:
      match b:
        case M.Booking{bid, room, start, end}: keep(Nat.is_eq(bid, id), b, remove(tail, id))

# Retain keys: a retry cannot resurrect a cancelled booking.
def cancel(state: M.State, id: Nat) -> M.State:
  match state:
    case M.State{bs, keys}: M.State{remove(bs, id), keys}

def initial() -> M.State:
  M.State{Nil{}, Nil{}}
