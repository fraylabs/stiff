import Base
import ./engine.bend as E

# Fixed observations of returned fields. Laws and witnesses use this module,
# independently of the mutable accounting implementation.
def state(outcome: E.Outcome) -> E.State:
  match outcome:
    case E.Outcome{status, next}: next

def total(state: E.State) -> Nat:
  match state:
    case E.State{alice, bob, keys}: Nat.add(alice, bob)

def rejected_state(outcome: E.Outcome, original: E.State) -> E.State:
  match outcome:
    case E.Outcome{E.Rejected{}, next}: next
    case E.Outcome{other, next}: original

def nonnegative(state: E.State) -> Bool:
  match state:
    case E.State{alice, bob, keys}: Bool.and(Nat.is_ge(alice, 0n), Nat.is_ge(bob, 0n))

# Observations used by the inductive laws (not alternate implementations).
def moved_total(fallback: Nat, moved: E.Movement) -> Nat:
  match moved:
    case E.NoFunds{}: fallback
    case E.Moved{source, destination}: Nat.add(source, destination)
