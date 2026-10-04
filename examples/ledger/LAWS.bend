import Base
import ./engine.bend as E
import ./spec.bend as S

law add_successor:
  for a: Nat
  for b: Nat
  {Nat.add(a, 1n+b) == 1n+Nat.add(a, b) : Nat}

law add_commutes:
  for +a: Nat
  for +b: Nat
  {Nat.add(a, b) == Nat.add(b, a) : Nat}

law move_conserves:
  for +amount: Nat
  for +source: Nat
  for +destination: Nat
  {S.moved_total(Nat.add(source, destination), E.move(amount, source, destination))
    == Nat.add(source, destination) : Nat}

law nat_nonnegative:
  for n: Nat
  {Nat.is_ge(n, 0n) == True{} : Bool}

law balances_nonnegative:
  for s: E.State
  {S.nonnegative(s) == True{} : Bool}

law key_equals_itself:
  for n: Nat
  {Nat.is_eq(n, n) == True{} : Bool}

law remembered_key:
  for +key: Nat
  for keys: List<&2, Nat>
  {E.seen(key <> keys, key) == True{} : Bool}

law finish_conserves:
  for +moved: E.Movement
  for +original: E.State
  for +key: Nat
  for +direction: E.Direction
  {S.total(S.state(E.finish(moved, original, key, direction)))
    == S.moved_total(S.total(original), moved) : Nat}

law fresh_conserves:
  for +original: E.State
  for +key: Nat
  for +direction: E.Direction
  for +amount: Nat
  {S.total(S.state(E.fresh(original, key, direction, amount))) == S.total(original) : Nat}

law dispatch_conserves:
  for duplicate: Bool
  for +original: E.State
  for +key: Nat
  for +direction: E.Direction
  for +amount: Nat
  {S.total(S.state(E.dispatch(duplicate, original, key, direction, amount))) == S.total(original) : Nat}

law transfer_conserves:
  for +original: E.State
  for +key: Nat
  for +direction: E.Direction
  for +amount: Nat
  {S.total(S.state(E.transfer(original, key, direction, amount))) == S.total(original) : Nat}

law finish_rejection_identity:
  for +moved: E.Movement
  for +original: E.State
  for +key: Nat
  for +direction: E.Direction
  {S.rejected_state(E.finish(moved, original, key, direction), original) == original : E.State}

law dispatch_rejection_identity:
  for duplicate: Bool
  for +original: E.State
  for +key: Nat
  for +direction: E.Direction
  for +amount: Nat
  {S.rejected_state(E.dispatch(duplicate, original, key, direction, amount), original) == original : E.State}

law rejected_transfer_unchanged:
  for +original: E.State
  for +key: Nat
  for +direction: E.Direction
  for +amount: Nat
  {S.rejected_state(E.transfer(original, key, direction, amount), original) == original : E.State}

law transfer_nonnegative:
  for original: E.State
  for key: Nat
  for direction: E.Direction
  for amount: Nat
  {S.nonnegative(S.state(E.transfer(original, key, direction, amount))) == True{} : Bool}

# The premise connects the movement to the real first transfer. It is not an axiom.
law finish_retry:
  for +moved: E.Movement
  for +original: E.State
  for +key: Nat
  for +direction: E.Direction
  for +amount: Nat
  for first: {S.state(E.transfer(original, key, direction, amount))
    == S.state(E.finish(moved, original, key, direction)) : E.State}
  {S.state(E.transfer(S.state(E.finish(moved, original, key, direction)), key, direction, amount))
    == S.state(E.finish(moved, original, key, direction)) : E.State}

law dispatch_retry:
  for duplicate: Bool
  for +alice: Nat
  for +bob: Nat
  for +keys: List<&2, Nat>
  for +key: Nat
  for +direction: E.Direction
  for +amount: Nat
  for seen: {E.seen(keys, key) == duplicate : Bool}
  {S.state(E.transfer(S.state(E.dispatch(duplicate, E.State{alice, bob, keys}, key, direction, amount)), key, direction, amount))
    == S.state(E.dispatch(duplicate, E.State{alice, bob, keys}, key, direction, amount)) : E.State}

law same_key_twice_equals_once:
  for +original: E.State
  for +key: Nat
  for +direction: E.Direction
  for +amount: Nat
  {S.state(E.transfer(S.state(E.transfer(original, key, direction, amount)), key, direction, amount))
    == S.state(E.transfer(original, key, direction, amount)) : E.State}

law insufficient_funds:
  for +source: Nat
  for +extra: Nat
  for +destination: Nat
  {E.move(Nat.add(source, 1n+extra), source, destination) == E.NoFunds{} : E.Movement}

law exact_movement:
  for +amount: Nat
  for +remainder: Nat
  for +destination: Nat
  {E.move(amount, Nat.add(amount, remainder), destination)
    == E.Moved{remainder, Nat.add(amount, destination)} : E.Movement}

law alice_exact_debit_credit:
  for +amount: Nat
  for +remainder: Nat
  for +bob: Nat
  for +keys: List<&2, Nat>
  for +key: Nat
  {E.fresh(E.State{Nat.add(amount, remainder), bob, keys}, key, E.AliceToBob{}, amount)
    == E.Outcome{E.Applied{}, E.State{remainder, Nat.add(amount, bob), key <> keys}} : E.Outcome}

law bob_exact_debit_credit:
  for +amount: Nat
  for +remainder: Nat
  for +alice: Nat
  for +keys: List<&2, Nat>
  for +key: Nat
  {E.fresh(E.State{alice, Nat.add(amount, remainder), keys}, key, E.BobToAlice{}, amount)
    == E.Outcome{E.Applied{}, E.State{Nat.add(amount, alice), remainder, key <> keys}} : E.Outcome}

law alice_overdraft_rejected:
  for +alice: Nat
  for +bob: Nat
  for +extra: Nat
  for +keys: List<&2, Nat>
  for +key: Nat
  {E.fresh(E.State{alice, bob, keys}, key, E.AliceToBob{}, Nat.add(alice, 1n+extra))
    == E.Outcome{E.Rejected{}, E.State{alice, bob, keys}} : E.Outcome}

law bob_overdraft_rejected:
  for +alice: Nat
  for +bob: Nat
  for +extra: Nat
  for +keys: List<&2, Nat>
  for +key: Nat
  {E.fresh(E.State{alice, bob, keys}, key, E.BobToAlice{}, Nat.add(bob, 1n+extra))
    == E.Outcome{E.Rejected{}, E.State{alice, bob, keys}} : E.Outcome}

# Any later input using a remembered key preserves the complete state.
law remembered_key_preserves_state:
  for +alice: Nat
  for +bob: Nat
  for +keys: List<&2, Nat>
  for +key: Nat
  for +direction: E.Direction
  for +amount: Nat
  {S.state(E.transfer(E.State{alice, bob, key <> keys}, key, direction, amount))
    == E.State{alice, bob, key <> keys} : E.State}

law initial_state_exact:
  {E.initial() == E.State{100n, 100n, Nil{}} : E.State}

law initial_supply:
  {S.total(E.initial()) == 200n : Nat}
