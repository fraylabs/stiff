import Base
import ./engine.bend as E
import ./spec.bend as S

# Concrete instances used to show a false rule, even when the generic proof's
# first diagnostic names an earlier helper. These supplement the universal laws.
law transfer_conserves_example:
  {S.total(S.state(E.transfer(E.State{10n, 10n, Nil{}}, 7n, E.AliceToBob{}, 2n))) == 20n : Nat}
def transfer_conserves_example():
  {==}

law insufficient_conserves_example:
  {S.total(S.state(E.transfer(E.State{10n, 10n, Nil{}}, 7n, E.AliceToBob{}, 11n))) == 20n : Nat}
def insufficient_conserves_example():
  {==}

law rejected_transfer_unchanged_example:
  {S.state(E.transfer(E.State{10n, 10n, Nil{}}, 7n, E.AliceToBob{}, 11n)) == E.State{10n, 10n, Nil{}} : E.State}
def rejected_transfer_unchanged_example():
  {==}

law same_key_twice_equals_once_example:
  {S.state(E.transfer(S.state(E.transfer(E.State{10n, 10n, Nil{}}, 7n, E.AliceToBob{}, 2n)), 7n, E.AliceToBob{}, 2n))
    == S.state(E.transfer(E.State{10n, 10n, Nil{}}, 7n, E.AliceToBob{}, 2n)) : E.State}
def same_key_twice_equals_once_example():
  {==}

law alice_exact_debit_credit_example:
  {E.transfer(E.State{10n, 10n, Nil{}}, 7n, E.AliceToBob{}, 2n)
    == E.Outcome{E.Applied{}, E.State{8n, 12n, [7n]}} : E.Outcome}
def alice_exact_debit_credit_example():
  {==}
