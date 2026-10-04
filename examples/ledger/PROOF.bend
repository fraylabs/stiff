import Base
import ./engine.bend as E
import ./spec.bend as S
import ./LAWS.bend as L

law add_zero:
  for a: Nat
  {Nat.add(a, 0n) == a : Nat}

def add_zero(a):
  match a:
    case 0n: {==}
    case 1n+p:
      %add_zero(p) : {1n+Nat.add(p, 0n) == 1n+_ : Nat}
      {==}

def L.add_successor(a, b):
  match a:
    case 0n: {==}
    case 1n+p:
      %L.add_successor(p, b) : {1n+Nat.add(p, 1n+b) == 1n+_ : Nat}
      {==}

def L.add_commutes(a, b):
  match a:
    case 0n: Equal.sym(Nat, Nat.add(b, 0n), b, add_zero(b))
    case 1n+p:
      Equal.trans(Nat, 1n+Nat.add(p, b), 1n+Nat.add(b, p), Nat.add(b, 1n+p),
        Equal.cong(Nat, Nat, x => 1n+x, Nat.add(p, b), Nat.add(b, p), L.add_commutes(p, b)),
        Equal.sym(Nat, Nat.add(b, 1n+p), 1n+Nat.add(b, p), L.add_successor(b, p)))

def L.move_conserves(amount, source, destination):
  match amount:
    case 0n: {==}
    case 1n+rest:
      match source:
        case 0n: {==}
        case 1n+balance:
          %L.add_successor(balance, destination) :
            {S.moved_total(_, E.move(rest, balance, 1n+destination)) == _ : Nat}
          L.move_conserves(rest, balance, 1n+destination)

def L.nat_nonnegative(n):
  match n:
    case 0n: {==}
    case 1n+p: {==}

def L.balances_nonnegative(s):
  match s:
    case E.State{alice, bob, keys}:
      match alice bob:
        case 0n 0n: {==}
        case 0n 1n+b: {==}
        case 1n+a 0n: {==}
        case 1n+a 1n+b: {==}

def L.key_equals_itself(n):
  match n:
    case 0n: {==}
    case 1n+p: L.key_equals_itself(p)

def L.remembered_key(key, keys):
  %Equal.sym(Bool, Nat.is_eq(key, key), True{}, L.key_equals_itself(key)) : {Bool.or(_, E.seen(keys, key)) == True{} : Bool}
  {==}

def L.finish_conserves(moved, original, key, direction):
  match moved:
    case E.NoFunds{}: {==}
    case E.Moved{source, destination}:
      match original:
        case E.State{alice, bob, keys}:
          match direction:
            case E.AliceToBob{}: {==}
            case E.BobToAlice{}: L.add_commutes(destination, source)

def L.fresh_conserves(original, key, direction, amount):
  match original:
    case E.State{alice, bob, keys}:
      match direction:
        case E.AliceToBob{}:
          Equal.trans(Nat,
            S.total(S.state(E.finish(E.move(amount, alice, bob), original, key, direction))),
            S.moved_total(Nat.add(alice, bob), E.move(amount, alice, bob)), Nat.add(alice, bob),
            L.finish_conserves(E.move(amount, alice, bob), original, key, direction),
            L.move_conserves(amount, alice, bob))
        case E.BobToAlice{}:
          Equal.trans(Nat,
            S.total(S.state(E.finish(E.move(amount, bob, alice), original, key, direction))),
            S.moved_total(Nat.add(alice, bob), E.move(amount, bob, alice)), Nat.add(alice, bob),
            L.finish_conserves(E.move(amount, bob, alice), original, key, direction),
            Equal.trans(Nat,
              S.moved_total(Nat.add(alice, bob), E.move(amount, bob, alice)),
              S.moved_total(Nat.add(bob, alice), E.move(amount, bob, alice)), Nat.add(alice, bob),
              Equal.cong(Nat, Nat, n => S.moved_total(n, E.move(amount, bob, alice)),
                Nat.add(alice, bob), Nat.add(bob, alice), L.add_commutes(alice, bob)),
              Equal.trans(Nat, S.moved_total(Nat.add(bob, alice), E.move(amount, bob, alice)),
                Nat.add(bob, alice), Nat.add(alice, bob),
                L.move_conserves(amount, bob, alice), L.add_commutes(bob, alice))))

def L.dispatch_conserves(duplicate, original, key, direction, amount):
  match duplicate:
    case True{}: {==}
    case False{}: L.fresh_conserves(original, key, direction, amount)

def L.transfer_conserves(original, key, direction, amount):
  match original:
    case E.State{alice, bob, keys}:
      L.dispatch_conserves(E.seen(keys, key), original, key, direction, amount)

def L.finish_rejection_identity(moved, original, key, direction):
  match moved:
    case E.NoFunds{}: {==}
    case E.Moved{source, destination}:
      match original:
        case E.State{alice, bob, keys}:
          match direction:
            case E.AliceToBob{}: {==}
            case E.BobToAlice{}: {==}

def L.dispatch_rejection_identity(duplicate, original, key, direction, amount):
  match duplicate:
    case True{}: {==}
    case False{}:
      match original:
        case E.State{alice, bob, keys}:
          match direction:
            case E.AliceToBob{}: L.finish_rejection_identity(E.move(amount, alice, bob), original, key, direction)
            case E.BobToAlice{}: L.finish_rejection_identity(E.move(amount, bob, alice), original, key, direction)

def L.rejected_transfer_unchanged(original, key, direction, amount):
  match original:
    case E.State{alice, bob, keys}:
      L.dispatch_rejection_identity(E.seen(keys, key), original, key, direction, amount)

def L.transfer_nonnegative(original, key, direction, amount):
  L.balances_nonnegative(S.state(E.transfer(original, key, direction, amount)))

def L.finish_retry(moved, original, key, direction, amount, first):
  match moved:
    case E.NoFunds{}: first
    case E.Moved{source, destination}:
      match original:
        case E.State{alice, bob, keys}:
          match direction:
            case E.AliceToBob{}:
              %Equal.sym(Bool, E.seen(key <> keys, key), True{}, L.remembered_key(key, keys)) :
                {S.state(E.dispatch(_, E.State{source, destination, key <> keys}, key, direction, amount))
                  == E.State{source, destination, key <> keys} : E.State}
              {==}
            case E.BobToAlice{}:
              %Equal.sym(Bool, E.seen(key <> keys, key), True{}, L.remembered_key(key, keys)) :
                {S.state(E.dispatch(_, E.State{destination, source, key <> keys}, key, direction, amount))
                  == E.State{destination, source, key <> keys} : E.State}
              {==}

def L.dispatch_retry(duplicate, alice, bob, keys, key, direction, amount, seen):
  match duplicate:
    case True{}:
      %Equal.sym(Bool, E.seen(keys, key), True{}, seen) :
        {S.state(E.dispatch(_, E.State{alice, bob, keys}, key, direction, amount)) == E.State{alice, bob, keys} : E.State}
      {==}
    case False{}:
      match direction:
        case E.AliceToBob{}:
          L.finish_retry(E.move(amount, alice, bob), E.State{alice, bob, keys}, key, direction, amount,
            Equal.cong(Bool, E.State, d => S.state(E.dispatch(d, E.State{alice, bob, keys}, key, direction, amount)),
              E.seen(keys, key), False{}, seen))
        case E.BobToAlice{}:
          L.finish_retry(E.move(amount, bob, alice), E.State{alice, bob, keys}, key, direction, amount,
            Equal.cong(Bool, E.State, d => S.state(E.dispatch(d, E.State{alice, bob, keys}, key, direction, amount)),
              E.seen(keys, key), False{}, seen))

def L.same_key_twice_equals_once(original, key, direction, amount):
  match original:
    case E.State{alice, bob, keys}:
      L.dispatch_retry(E.seen(keys, key), alice, bob, keys, key, direction, amount, {==})

def L.insufficient_funds(source, extra, destination):
  match source:
    case 0n: {==}
    case 1n+balance: L.insufficient_funds(balance, extra, 1n+destination)

def L.exact_movement(amount, remainder, destination):
  match amount:
    case 0n: {==}
    case 1n+rest:
      %L.add_successor(rest, destination) :
        {E.move(rest, Nat.add(rest, remainder), 1n+destination) == E.Moved{remainder, _} : E.Movement}
      L.exact_movement(rest, remainder, 1n+destination)

def L.alice_exact_debit_credit(amount, remainder, bob, keys, key):
  %Equal.sym(E.Movement, E.move(amount, Nat.add(amount, remainder), bob),
      E.Moved{remainder, Nat.add(amount, bob)}, L.exact_movement(amount, remainder, bob)) :
    {E.finish(_, E.State{Nat.add(amount, remainder), bob, keys}, key, E.AliceToBob{})
      == E.Outcome{E.Applied{}, E.State{remainder, Nat.add(amount, bob), key <> keys}} : E.Outcome}
  {==}

def L.bob_exact_debit_credit(amount, remainder, alice, keys, key):
  %Equal.sym(E.Movement, E.move(amount, Nat.add(amount, remainder), alice),
      E.Moved{remainder, Nat.add(amount, alice)}, L.exact_movement(amount, remainder, alice)) :
    {E.finish(_, E.State{alice, Nat.add(amount, remainder), keys}, key, E.BobToAlice{})
      == E.Outcome{E.Applied{}, E.State{Nat.add(amount, alice), remainder, key <> keys}} : E.Outcome}
  {==}

def L.alice_overdraft_rejected(alice, bob, extra, keys, key):
  %Equal.sym(E.Movement, E.move(Nat.add(alice, 1n+extra), alice, bob), E.NoFunds{},
      L.insufficient_funds(alice, extra, bob)) :
    {E.finish(_, E.State{alice, bob, keys}, key, E.AliceToBob{})
      == E.Outcome{E.Rejected{}, E.State{alice, bob, keys}} : E.Outcome}
  {==}

def L.bob_overdraft_rejected(alice, bob, extra, keys, key):
  %Equal.sym(E.Movement, E.move(Nat.add(bob, 1n+extra), bob, alice), E.NoFunds{},
      L.insufficient_funds(bob, extra, alice)) :
    {E.finish(_, E.State{alice, bob, keys}, key, E.BobToAlice{})
      == E.Outcome{E.Rejected{}, E.State{alice, bob, keys}} : E.Outcome}
  {==}

def L.remembered_key_preserves_state(alice, bob, keys, key, direction, amount):
  %Equal.sym(Bool, E.seen(key <> keys, key), True{}, L.remembered_key(key, keys)) :
    {S.state(E.dispatch(_, E.State{alice, bob, key <> keys}, key, direction, amount))
      == E.State{alice, bob, key <> keys} : E.State}
  {==}

def L.initial_state_exact():
  {==}

def L.initial_supply():
  {==}
