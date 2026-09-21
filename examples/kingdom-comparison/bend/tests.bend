import Base
import ./engine.bend as Kingdom

def same_outcome(actual: Kingdom.Outcome, accepted: Bool,
                 expected: Kingdom.State) -> Bool:
  match actual:
    case Kingdom.Outcome{got_accepted, got_state}:
      Bool.and(Kingdom.bool_eq(got_accepted, accepted),
        Kingdom.state_eq(got_state, expected))

def rule_cases() -> Bool:
  Bool.and(
    same_outcome(Kingdom.transition(Kingdom.initial(), Kingdom.Buy0{}), False{},
      Kingdom.initial()),
  Bool.and(
    same_outcome(Kingdom.transition(Kingdom.initial(), Kingdom.Mortgage0{}), True{},
      Kingdom.State{25, 20, 95, 0, True{}, 1}),
  Bool.and(
    same_outcome(Kingdom.transition(Kingdom.State{25, 20, 95, 0, True{}, 1}, Kingdom.Buy1{}), False{},
      Kingdom.State{25, 20, 95, 0, True{}, 1}),
  Bool.and(
    same_outcome(Kingdom.transition(Kingdom.State{25, 20, 95, 0, True{}, 1}, Kingdom.Pass1{}), True{},
      Kingdom.State{25, 20, 95, 0, True{}, 0}),
  Bool.and(
    same_outcome(Kingdom.transition(Kingdom.State{25, 20, 95, 0, True{}, 0}, Kingdom.Repay0{}), True{},
      Kingdom.State{20, 20, 100, 0, False{}, 1}),
  Bool.and(
    same_outcome(Kingdom.transition(Kingdom.State{20, 20, 100, 0, False{}, 1}, Kingdom.Buy1{}), True{},
      Kingdom.State{30, 10, 100, 1, False{}, 0}),
  Bool.and(
    same_outcome(Kingdom.transition(Kingdom.State{30, 10, 100, 1, False{}, 0}, Kingdom.Pass0{}), True{},
      Kingdom.State{30, 10, 100, 1, False{}, 1}),
  Bool.and(
    same_outcome(Kingdom.transition(Kingdom.State{30, 10, 100, 1, False{}, 1}, Kingdom.Mortgage1{}), True{},
      Kingdom.State{30, 15, 95, 1, True{}, 0}),
  Bool.and(
    same_outcome(Kingdom.transition(Kingdom.State{30, 15, 95, 1, True{}, 0}, Kingdom.Invalid{}), False{},
      Kingdom.State{30, 15, 95, 1, True{}, 0}),
  Bool.and(
    same_outcome(Kingdom.transition(Kingdom.State{30, 15, 95, 1, True{}, 0}, Kingdom.Repay1{}), False{},
      Kingdom.State{30, 15, 95, 1, True{}, 0}),
    same_outcome(Kingdom.transition(Kingdom.State{30, 15, 95, 1, True{}, 1}, Kingdom.Repay1{}), True{},
      Kingdom.State{30, 10, 100, 1, False{}, 0})
  ))))))))))

def valid_reachable(state: Kingdom.State) -> Bool:
  match state:
    case Kingdom.State{gold0, gold1, bank, owner, mortgaged, turn}:
      Bool.and(U32.is_eq(U32.add(U32.add(gold0, gold1), bank), 140),
        Bool.and(U32.is_le(owner, 1), U32.is_le(turn, 1)))

def turn_changed(before: Kingdom.State, after: Kingdom.State) -> Bool:
  match before after:
    case Kingdom.State{g0, g1, bank, owner, mortgaged, 0} Kingdom.State{h0, h1, hbank, howner, hmortgaged, next}:
      U32.is_eq(next, 1)
    case Kingdom.State{g0, g1, bank, owner, mortgaged, 1} Kingdom.State{h0, h1, hbank, howner, hmortgaged, next}:
      U32.is_eq(next, 0)
    case other_before other_after: False{}

def step_contract(before: Kingdom.State, outcome: Kingdom.Outcome) -> Bool:
  match outcome:
    case Kingdom.Outcome{True{}, +after}:
      Bool.and(valid_reachable(after), turn_changed(before, after))
    case Kingdom.Outcome{False{}, after}:
      Kingdom.state_eq(before, after)

def explore(+depth: Nat, +state: Kingdom.State) -> Bool:
  match depth:
    case 0n: valid_reachable(state)
    case 1n+remaining:
      +o0 = Kingdom.transition(state, Kingdom.Buy0{})
      +s0 = Kingdom.outcome_state(o0)
      +o1 = Kingdom.transition(state, Kingdom.Buy1{})
      +s1 = Kingdom.outcome_state(o1)
      +o2 = Kingdom.transition(state, Kingdom.Mortgage0{})
      +s2 = Kingdom.outcome_state(o2)
      +o3 = Kingdom.transition(state, Kingdom.Mortgage1{})
      +s3 = Kingdom.outcome_state(o3)
      +o4 = Kingdom.transition(state, Kingdom.Repay0{})
      +s4 = Kingdom.outcome_state(o4)
      +o5 = Kingdom.transition(state, Kingdom.Repay1{})
      +s5 = Kingdom.outcome_state(o5)
      +o6 = Kingdom.transition(state, Kingdom.Pass0{})
      +s6 = Kingdom.outcome_state(o6)
      +o7 = Kingdom.transition(state, Kingdom.Pass1{})
      +s7 = Kingdom.outcome_state(o7)
      +o8 = Kingdom.transition(state, Kingdom.Invalid{})
      +s8 = Kingdom.outcome_state(o8)
      Bool.and(step_contract(state, o0),
      Bool.and(explore(remaining, s0),
      Bool.and(step_contract(state, o1),
      Bool.and(explore(remaining, s1),
      Bool.and(step_contract(state, o2),
      Bool.and(explore(remaining, s2),
      Bool.and(step_contract(state, o3),
      Bool.and(explore(remaining, s3),
      Bool.and(step_contract(state, o4),
      Bool.and(explore(remaining, s4),
      Bool.and(step_contract(state, o5),
      Bool.and(explore(remaining, s5),
      Bool.and(step_contract(state, o6),
      Bool.and(explore(remaining, s6),
      Bool.and(step_contract(state, o7),
      Bool.and(explore(remaining, s7),
      Bool.and(step_contract(state, o8), explore(remaining, s8)
      )))))))))))))))))

def finish(ok: Bool) -> IO(Unit):
  match ok:
    case True{}: IO.print("all Bend kingdom tests passed")
    case False{}: IO.die(Unit, 1, "Bend kingdom test failure")

def main() -> IO(Unit):
  finish(Bool.and(rule_cases(), explore(6n, Kingdom.initial())))
