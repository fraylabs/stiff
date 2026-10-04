import Base

# Two fixed accounts; money is an exact natural number of demo cents.
type Direction is Data:
  AliceToBob{}
  BobToAlice{}

type State is Data:
  State{alice: Nat, bob: Nat, keys: List<&2, Nat>}

type Status is Data:
  Applied{}
  Replayed{}
  Rejected{}

type Outcome is Data:
  Outcome{status: Status, state: State}

type Movement is Data:
  NoFunds{}
  Moved{source: Nat, destination: Nat}

# NoFunds means insufficient funds. Partial work never escapes this pure function.
def move(amount: Nat, source: Nat, destination: Nat) -> Movement:
  match amount:
    case 0n: Moved{source, destination}
    case 1n+rest:
      match source:
        case 0n: NoFunds{}
        case 1n+balance: move(rest, balance, 1n+destination)

def seen(keys: List<&2, Nat>, +key: Nat) -> Bool:
  match keys:
    case Nil{}: False{}
    case head <> tail: Bool.or(Nat.is_eq(head, key), seen(tail, key))

def finish(moved: Movement, +original: State, key: Nat, direction: Direction) -> Outcome:
  match moved:
    case NoFunds{}: Outcome{Rejected{}, original}
    case Moved{source, destination}:
      match original:
        case State{alice, bob, keys}:
          match direction:
            case AliceToBob{}: Outcome{Applied{}, State{source, destination, key <> keys}}
            case BobToAlice{}: Outcome{Applied{}, State{destination, source, key <> keys}}

def fresh(+state: State, key: Nat, +direction: Direction, amount: Nat) -> Outcome:
  match state:
    case State{alice, bob, keys}:
      match direction:
        case AliceToBob{}: finish(move(amount, alice, bob), state, key, direction)
        case BobToAlice{}: finish(move(amount, bob, alice), state, key, direction)

def dispatch(duplicate: Bool, +state: State, key: Nat, direction: Direction, amount: Nat) -> Outcome:
  match duplicate:
    case True{}: Outcome{Replayed{}, state}
    case False{}: fresh(state, key, direction, amount)

def transfer(+state: State, +key: Nat, direction: Direction, amount: Nat) -> Outcome:
  match state:
    case State{alice, bob, keys}:
      dispatch(seen(keys, key), state, key, direction, amount)

def initial() -> State:
  State{100n, 100n, Nil{}}
