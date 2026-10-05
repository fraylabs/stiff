import Base
import ./model.bend as M
import ./engine.bend as E
import ./spec.bend as S

law overlap_matches_half_open:
  for +a: M.Booking
  for +b: M.Booking
  {E.overlap(a, b) == S.overlap(a, b) : Bool}
def overlap_matches_half_open(a, b):
  match a b:
    case M.Booking{ai, ar, ast, ae} M.Booking{bi, br, bst, be}: {==}

law compatible_matches:
  for +a: M.Booking
  for +bs: List<&2, M.Booking>
  {E.compatible(a, bs) == S.compatible(a, bs) : Bool}
def compatible_matches(a, bs):
  match bs:
    case Nil{}: {==}
    case +b <> +tail:
      %Equal.sym(Bool, E.overlap(a, b), S.overlap(a, b), overlap_matches_half_open(a, b)) : {Bool.and(Bool.not(_), E.compatible(a, tail)) == S.compatible(a, b <> tail) : Bool}
      %Equal.sym(Bool, E.compatible(a, tail), S.compatible(a, tail), compatible_matches(a, tail)) : {Bool.and(Bool.not(S.overlap(a, b)), _) == S.compatible(a, b <> tail) : Bool}
      {==}

law safe_matches:
  for +bs: List<&2, M.Booking>
  {E.safe(bs) == S.safe(bs) : Bool}
def safe_matches(bs):
  match bs:
    case Nil{}: {==}
    case +b <> +tail:
      %Equal.sym(Bool, E.compatible(b, tail), S.compatible(b, tail), compatible_matches(b, tail)) : {Bool.and(_, E.safe(tail)) == S.safe(b <> tail) : Bool}
      %Equal.sym(Bool, E.safe(tail), S.safe(tail), safe_matches(tail)) : {Bool.and(S.compatible(b, tail), _) == S.safe(b <> tail) : Bool}
      {==}

law finish_safe:
  for ok: Bool
  for +bs: List<&2, M.Booking>
  for keys: List<&2, Nat>
  for key: Nat
  for +b: M.Booking
  for checked: {E.safe(b <> bs) == ok : Bool}
  {S.accepted_safe(E.finish(ok, M.State{bs, keys}, key, b)) == True{} : Bool}
def finish_safe(ok, bs, keys, key, b, checked):
  match ok:
    case False{}: {==}
    case True{}:
      Equal.trans(Bool, S.safe(b <> bs), E.safe(b <> bs), True{},
        Equal.sym(Bool, E.safe(b <> bs), S.safe(b <> bs), safe_matches(b <> bs)), checked)

law checked_safe:
  for valid: Bool
  for +original: M.State
  for key: Nat
  for +b: M.Booking
  {S.accepted_safe(E.checked(valid, original, key, b)) == True{} : Bool}
def checked_safe(valid, original, key, b):
  match valid:
    case False{}: {==}
    case True{}:
      match original:
        case M.State{bs, keys}: finish_safe(E.safe(b <> bs), bs, keys, key, b, {==})

law dispatch_safe:
  for duplicate: Bool
  for +original: M.State
  for key: Nat
  for +b: M.Booking
  {S.accepted_safe(E.dispatch(duplicate, original, key, b)) == True{} : Bool}
def dispatch_safe(duplicate, original, key, b):
  match duplicate:
    case True{}: {==}
    case False{}: checked_safe(E.valid(b), original, key, b)

# No premise that the input schedule is safe; every Applied result is safe.
law no_double_booking:
  for +original: M.State
  for +key: Nat
  for +room: Nat
  for +start: Nat
  for +end: Nat
  {S.accepted_safe(E.book(original, key, room, start, end)) == True{} : Bool}
def no_double_booking(original, key, room, start, end):
  match original:
    case M.State{bs, keys}: dispatch_safe(E.seen(keys, key), original, key, M.Booking{key, room, start, end})

law finish_rejection:
  for ok: Bool
  for +original: M.State
  for key: Nat
  for b: M.Booking
  {S.rejected_state(E.finish(ok, original, key, b), original) == original : M.State}
def finish_rejection(ok, original, key, b):
  match ok:
    case False{}: {==}
    case True{}:
      match original:
        case M.State{bs, keys}: {==}

law checked_rejection:
  for valid: Bool
  for +original: M.State
  for key: Nat
  for +b: M.Booking
  {S.rejected_state(E.checked(valid, original, key, b), original) == original : M.State}
def checked_rejection(valid, original, key, b):
  match valid:
    case False{}: {==}
    case True{}:
      match original:
        case M.State{bs, keys}: finish_rejection(E.safe(b <> bs), original, key, b)

law dispatch_rejection:
  for duplicate: Bool
  for +original: M.State
  for key: Nat
  for +b: M.Booking
  {S.rejected_state(E.dispatch(duplicate, original, key, b), original) == original : M.State}
def dispatch_rejection(duplicate, original, key, b):
  match duplicate:
    case True{}: {==}
    case False{}: checked_rejection(E.valid(b), original, key, b)

law rejected_request_unchanged:
  for +original: M.State
  for +key: Nat
  for +room: Nat
  for +start: Nat
  for +end: Nat
  {S.rejected_state(E.book(original, key, room, start, end), original) == original : M.State}
def rejected_request_unchanged(original, key, room, start, end):
  match original:
    case M.State{bs, keys}: dispatch_rejection(E.seen(keys, key), original, key, M.Booking{key, room, start, end})

law keep_matches:
  for hit: Bool
  for +b: M.Booking
  for +tail: List<&2, M.Booking>
  {E.keep(hit, b, tail) == S.retain(hit, b, tail) : List<&2, M.Booking>}
def keep_matches(hit, b, tail):
  match hit:
    case True{}: {==}
    case False{}: {==}

law remove_exact:
  for +bs: List<&2, M.Booking>
  for +id: Nat
  {E.remove(bs, id) == S.without(bs, id) : List<&2, M.Booking>}
def remove_exact(bs, id):
  match bs:
    case Nil{}: {==}
    case +b <> +tail:
      match b:
        case M.Booking{bid, room, start, end}:
          %Equal.sym(List<&2, M.Booking>, E.remove(tail, id), S.without(tail, id), remove_exact(tail, id)) : {E.keep(Nat.is_eq(bid, id), b, _) == S.without(b <> tail, id) : List<&2, M.Booking>}
          keep_matches(Nat.is_eq(bid, id), b, S.without(tail, id))

law cancelling_removes_exactly:
  for +bs: List<&2, M.Booking>
  for +keys: List<&2, Nat>
  for +id: Nat
  {E.cancel(M.State{bs, keys}, id) == M.State{S.without(bs, id), keys} : M.State}
def cancelling_removes_exactly(bs, keys, id):
  %Equal.sym(List<&2, M.Booking>, E.remove(bs, id), S.without(bs, id), remove_exact(bs, id)) : {M.State{_, keys} == M.State{S.without(bs, id), keys} : M.State}
  {==}

law key_reflexive:
  for key: Nat
  {Nat.is_eq(key, key) == True{} : Bool}
def key_reflexive(key):
  match key:
    case 0n: {==}
    case 1n+p: key_reflexive(p)

law remembered_key:
  for +key: Nat
  for keys: List<&2, Nat>
  {E.seen(key <> keys, key) == True{} : Bool}
def remembered_key(key, keys):
  %Equal.sym(Bool, Nat.is_eq(key, key), True{}, key_reflexive(key)) : {Bool.or(_, E.seen(keys, key)) == True{} : Bool}
  {==}

law finish_retry:
  for ok: Bool
  for +original: M.State
  for +key: Nat
  for +room: Nat
  for +start: Nat
  for +end: Nat
  for first: {S.state(E.book(original, key, room, start, end))
    == S.state(E.finish(ok, original, key, M.Booking{key, room, start, end})) : M.State}
  {S.state(E.book(S.state(E.finish(ok, original, key, M.Booking{key, room, start, end})), key, room, start, end))
    == S.state(E.finish(ok, original, key, M.Booking{key, room, start, end})) : M.State}
def finish_retry(ok, original, key, room, start, end, first):
  match ok:
    case False{}: first
    case True{}:
      match original:
        case M.State{bs, keys}:
          %Equal.sym(Bool, E.seen(key <> keys, key), True{}, remembered_key(key, keys)) :
            {S.state(E.dispatch(_, M.State{M.Booking{key, room, start, end} <> bs, key <> keys}, key, M.Booking{key, room, start, end}))
              == M.State{M.Booking{key, room, start, end} <> bs, key <> keys} : M.State}
          {==}

law checked_retry:
  for valid: Bool
  for +original: M.State
  for +key: Nat
  for +room: Nat
  for +start: Nat
  for +end: Nat
  for first: {S.state(E.book(original, key, room, start, end))
    == S.state(E.checked(valid, original, key, M.Booking{key, room, start, end})) : M.State}
  {S.state(E.book(S.state(E.checked(valid, original, key, M.Booking{key, room, start, end})), key, room, start, end))
    == S.state(E.checked(valid, original, key, M.Booking{key, room, start, end})) : M.State}
def checked_retry(valid, original, key, room, start, end, first):
  match valid:
    case False{}: first
    case True{}:
      match original:
        case M.State{bs, keys}: finish_retry(E.safe(M.Booking{key, room, start, end} <> bs), original, key, room, start, end, first)

law dispatch_retry:
  for duplicate: Bool
  for +bs: List<&2, M.Booking>
  for +keys: List<&2, Nat>
  for +key: Nat
  for +room: Nat
  for +start: Nat
  for +end: Nat
  for seen: {E.seen(keys, key) == duplicate : Bool}
  {S.state(E.book(S.state(E.dispatch(duplicate, M.State{bs, keys}, key, M.Booking{key, room, start, end})), key, room, start, end))
    == S.state(E.dispatch(duplicate, M.State{bs, keys}, key, M.Booking{key, room, start, end})) : M.State}
def dispatch_retry(duplicate, bs, keys, key, room, start, end, seen):
  match duplicate:
    case True{}:
      %Equal.sym(Bool, E.seen(keys, key), True{}, seen) :
        {S.state(E.dispatch(_, M.State{bs, keys}, key, M.Booking{key, room, start, end})) == M.State{bs, keys} : M.State}
      {==}
    case False{}:
      checked_retry(E.valid(M.Booking{key, room, start, end}), M.State{bs, keys}, key, room, start, end,
        Equal.cong(Bool, M.State, d => S.state(E.dispatch(d, M.State{bs, keys}, key, M.Booking{key, room, start, end})),
          E.seen(keys, key), False{}, seen))

law same_key_twice_equals_once:
  for +original: M.State
  for +key: Nat
  for +room: Nat
  for +start: Nat
  for +end: Nat
  {S.state(E.book(S.state(E.book(original, key, room, start, end)), key, room, start, end))
    == S.state(E.book(original, key, room, start, end)) : M.State}
def same_key_twice_equals_once(original, key, room, start, end):
  match original:
    case M.State{bs, keys}: dispatch_retry(E.seen(keys, key), bs, keys, key, room, start, end, {==})

# Cancellation also has state idempotency, even without an operation-key model.
law remove_step_retry:
  for hit: Bool
  for +bid: Nat
  for +room: Nat
  for +start: Nat
  for +end: Nat
  for +tail: List<&2, M.Booking>
  for +id: Nat
  for known: {Nat.is_eq(bid, id) == hit : Bool}
  for recur: {E.remove(E.remove(tail, id), id) == E.remove(tail, id) : List<&2, M.Booking>}
  {E.remove(E.keep(hit, M.Booking{bid, room, start, end}, E.remove(tail, id)), id)
    == E.keep(hit, M.Booking{bid, room, start, end}, E.remove(tail, id)) : List<&2, M.Booking>}
def remove_step_retry(hit, bid, room, start, end, tail, id, known, recur):
  match hit:
    case True{}: recur
    case False{}:
      %Equal.sym(Bool, Nat.is_eq(bid, id), False{}, known) :
        {E.keep(_, M.Booking{bid, room, start, end}, E.remove(E.remove(tail, id), id))
          == M.Booking{bid, room, start, end} <> E.remove(tail, id) : List<&2, M.Booking>}
      Equal.cong(List<&2, M.Booking>, List<&2, M.Booking>,
        bs => M.Booking{bid, room, start, end} <> bs,
        E.remove(E.remove(tail, id), id), E.remove(tail, id), recur)

law remove_retry:
  for +bs: List<&2, M.Booking>
  for +id: Nat
  {E.remove(E.remove(bs, id), id) == E.remove(bs, id) : List<&2, M.Booking>}
def remove_retry(bs, id):
  match bs:
    case Nil{}: {==}
    case +b <> +tail:
      match b:
        case M.Booking{bid, room, start, end}:
          remove_step_retry(Nat.is_eq(bid, id), bid, room, start, end, tail, id, {==}, remove_retry(tail, id))

law cancellation_twice_equals_once:
  for +state: M.State
  for +id: Nat
  {E.cancel(E.cancel(state, id), id) == E.cancel(state, id) : M.State}
def cancellation_twice_equals_once(state, id):
  match state:
    case M.State{bs, keys}:
      Equal.cong(List<&2, M.Booking>, M.State, xs => M.State{xs, keys},
        E.remove(E.remove(bs, id), id), E.remove(bs, id), remove_retry(bs, id))
