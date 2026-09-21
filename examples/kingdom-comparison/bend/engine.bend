import Base

type State is Data:
  State{
    gold0: U32,
    gold1: U32,
    bank: U32,
    owner: U32,
    mortgaged: Bool,
    turn: U32
  }

type Command is Data:
  Buy0{}
  Buy1{}
  Mortgage0{}
  Mortgage1{}
  Repay0{}
  Repay1{}
  Pass0{}
  Pass1{}
  Invalid{}

type Outcome is Data:
  Outcome{accepted: Bool, state: State}

def initial() -> State:
  State{20, 20, 100, 0, False{}, 0}

def parse(text: String) -> Command:
  match text:
    case "buy0": Buy0{}
    case "buy1": Buy1{}
    case "mortgage0": Mortgage0{}
    case "mortgage1": Mortgage1{}
    case "repay0": Repay0{}
    case "repay1": Repay1{}
    case "pass0": Pass0{}
    case "pass1": Pass1{}
    case other: Invalid{}

def choose(ok: Bool, accepted: State, rejected: State) -> Outcome:
  match ok:
    case True{}: Outcome{True{}, accepted}
    case False{}: Outcome{False{}, rejected}

def buy0(+gold0: U32, +gold1: U32, +bank: U32, +owner: U32,
         +mortgaged: Bool, +turn: U32) -> Outcome:
  ok = Bool.and(U32.is_eq(turn, 0),
    Bool.and(U32.is_eq(owner, 1),
      Bool.and(Bool.not(mortgaged), U32.is_ge(gold0, 10))))
  choose(ok,
    State{U32.sub(gold0, 10), U32.add(gold1, 10), bank, 0, mortgaged, 1},
    State{gold0, gold1, bank, owner, mortgaged, turn})

def buy1(+gold0: U32, +gold1: U32, +bank: U32, +owner: U32,
         +mortgaged: Bool, +turn: U32) -> Outcome:
  ok = Bool.and(U32.is_eq(turn, 1),
    Bool.and(U32.is_eq(owner, 0),
      Bool.and(Bool.not(mortgaged), U32.is_ge(gold1, 10))))
  choose(ok,
    State{U32.add(gold0, 10), U32.sub(gold1, 10), bank, 1, mortgaged, 0},
    State{gold0, gold1, bank, owner, mortgaged, turn})

def mortgage0(+gold0: U32, +gold1: U32, +bank: U32, +owner: U32,
              +mortgaged: Bool, +turn: U32) -> Outcome:
  ok = Bool.and(U32.is_eq(turn, 0),
    Bool.and(U32.is_eq(owner, 0),
      Bool.and(Bool.not(mortgaged), U32.is_ge(bank, 5))))
  choose(ok,
    State{U32.add(gold0, 5), gold1, U32.sub(bank, 5), owner, True{}, 1},
    State{gold0, gold1, bank, owner, mortgaged, turn})

def mortgage1(+gold0: U32, +gold1: U32, +bank: U32, +owner: U32,
              +mortgaged: Bool, +turn: U32) -> Outcome:
  ok = Bool.and(U32.is_eq(turn, 1),
    Bool.and(U32.is_eq(owner, 1),
      Bool.and(Bool.not(mortgaged), U32.is_ge(bank, 5))))
  choose(ok,
    State{gold0, U32.add(gold1, 5), U32.sub(bank, 5), owner, True{}, 0},
    State{gold0, gold1, bank, owner, mortgaged, turn})

def repay0(+gold0: U32, +gold1: U32, +bank: U32, +owner: U32,
           +mortgaged: Bool, +turn: U32) -> Outcome:
  ok = Bool.and(U32.is_eq(turn, 0),
    Bool.and(U32.is_eq(owner, 0),
      Bool.and(mortgaged, U32.is_ge(gold0, 5))))
  choose(ok,
    State{U32.sub(gold0, 5), gold1, U32.add(bank, 5), owner, False{}, 1},
    State{gold0, gold1, bank, owner, mortgaged, turn})

def repay1(+gold0: U32, +gold1: U32, +bank: U32, +owner: U32,
           +mortgaged: Bool, +turn: U32) -> Outcome:
  ok = Bool.and(U32.is_eq(turn, 1),
    Bool.and(U32.is_eq(owner, 1),
      Bool.and(mortgaged, U32.is_ge(gold1, 5))))
  choose(ok,
    State{gold0, U32.sub(gold1, 5), U32.add(bank, 5), owner, False{}, 0},
    State{gold0, gold1, bank, owner, mortgaged, turn})

def pass0(+gold0: U32, +gold1: U32, +bank: U32, +owner: U32,
          +mortgaged: Bool, +turn: U32) -> Outcome:
  choose(U32.is_eq(turn, 0),
    State{gold0, gold1, bank, owner, mortgaged, 1},
    State{gold0, gold1, bank, owner, mortgaged, turn})

def pass1(+gold0: U32, +gold1: U32, +bank: U32, +owner: U32,
          +mortgaged: Bool, +turn: U32) -> Outcome:
  choose(U32.is_eq(turn, 1),
    State{gold0, gold1, bank, owner, mortgaged, 0},
    State{gold0, gold1, bank, owner, mortgaged, turn})

def transition(state: State, command: Command) -> Outcome:
  match state:
    case State{gold0, gold1, bank, owner, mortgaged, turn}:
      match command:
        case Buy0{}: buy0(gold0, gold1, bank, owner, mortgaged, turn)
        case Buy1{}: buy1(gold0, gold1, bank, owner, mortgaged, turn)
        case Mortgage0{}: mortgage0(gold0, gold1, bank, owner, mortgaged, turn)
        case Mortgage1{}: mortgage1(gold0, gold1, bank, owner, mortgaged, turn)
        case Repay0{}: repay0(gold0, gold1, bank, owner, mortgaged, turn)
        case Repay1{}: repay1(gold0, gold1, bank, owner, mortgaged, turn)
        case Pass0{}: pass0(gold0, gold1, bank, owner, mortgaged, turn)
        case Pass1{}: pass1(gold0, gold1, bank, owner, mortgaged, turn)
        case Invalid{}:
          Outcome{False{}, State{gold0, gold1, bank, owner, mortgaged, turn}}

def bool_eq(a: Bool, b: Bool) -> Bool:
  Bool.not(Bool.xor(a, b))

def state_eq(a: State, b: State) -> Bool:
  match a b:
    case State{a0, a1, ab, ao, am, at} State{b0, b1, bb, bo, bm, bt}:
      Bool.and(U32.is_eq(a0, b0),
        Bool.and(U32.is_eq(a1, b1),
          Bool.and(U32.is_eq(ab, bb),
            Bool.and(U32.is_eq(ao, bo),
              Bool.and(bool_eq(am, bm), U32.is_eq(at, bt))))))

def outcome_state(outcome: Outcome) -> State:
  match outcome:
    case Outcome{accepted, state}: state

def outcome_accepted(outcome: Outcome) -> Bool:
  match outcome:
    case Outcome{accepted, state}: accepted

def total(state: State) -> U32:
  match state:
    case State{gold0, gold1, bank, owner, mortgaged, turn}:
      U32.add(U32.add(gold0, gold1), bank)
