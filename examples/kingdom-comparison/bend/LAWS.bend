import Base
import ./engine.bend as Kingdom

law initial_state_exact:
  {Kingdom.initial() == Kingdom.State{20, 20, 100, 0, False{}, 0} : Kingdom.State}

law invalid_is_identity:
  for state: Kingdom.State
  {Kingdom.transition(state, Kingdom.Invalid{}) == Kingdom.Outcome{False{}, state} : Kingdom.Outcome}

law pass0_changes_only_turn:
  for gold0: U32
  for gold1: U32
  for bank: U32
  for owner: U32
  for mortgaged: Bool
  {Kingdom.transition(Kingdom.State{gold0, gold1, bank, owner, mortgaged, 0}, Kingdom.Pass0{})
    == Kingdom.Outcome{True{}, Kingdom.State{gold0, gold1, bank, owner, mortgaged, 1}} : Kingdom.Outcome}

law pass1_changes_only_turn:
  for gold0: U32
  for gold1: U32
  for bank: U32
  for owner: U32
  for mortgaged: Bool
  {Kingdom.transition(Kingdom.State{gold0, gold1, bank, owner, mortgaged, 1}, Kingdom.Pass1{})
    == Kingdom.Outcome{True{}, Kingdom.State{gold0, gold1, bank, owner, mortgaged, 0}} : Kingdom.Outcome}

law wrong_turn_buy0_rejected:
  for gold0: U32
  for gold1: U32
  for bank: U32
  for owner: U32
  for mortgaged: Bool
  {Kingdom.transition(Kingdom.State{gold0, gold1, bank, owner, mortgaged, 1}, Kingdom.Buy0{})
    == Kingdom.Outcome{False{}, Kingdom.State{gold0, gold1, bank, owner, mortgaged, 1}} : Kingdom.Outcome}

law wrong_turn_mortgage0_rejected:
  for gold0: U32
  for gold1: U32
  for bank: U32
  for owner: U32
  for mortgaged: Bool
  {Kingdom.transition(Kingdom.State{gold0, gold1, bank, owner, mortgaged, 1}, Kingdom.Mortgage0{})
    == Kingdom.Outcome{False{}, Kingdom.State{gold0, gold1, bank, owner, mortgaged, 1}} : Kingdom.Outcome}

law wrong_turn_repay0_rejected:
  for gold0: U32
  for gold1: U32
  for bank: U32
  for owner: U32
  for mortgaged: Bool
  {Kingdom.transition(Kingdom.State{gold0, gold1, bank, owner, mortgaged, 1}, Kingdom.Repay0{})
    == Kingdom.Outcome{False{}, Kingdom.State{gold0, gold1, bank, owner, mortgaged, 1}} : Kingdom.Outcome}

law wrong_turn_buy1_rejected:
  for gold0: U32
  for gold1: U32
  for bank: U32
  for owner: U32
  for mortgaged: Bool
  {Kingdom.transition(Kingdom.State{gold0, gold1, bank, owner, mortgaged, 0}, Kingdom.Buy1{})
    == Kingdom.Outcome{False{}, Kingdom.State{gold0, gold1, bank, owner, mortgaged, 0}} : Kingdom.Outcome}

law wrong_turn_mortgage1_rejected:
  for gold0: U32
  for gold1: U32
  for bank: U32
  for owner: U32
  for mortgaged: Bool
  {Kingdom.transition(Kingdom.State{gold0, gold1, bank, owner, mortgaged, 0}, Kingdom.Mortgage1{})
    == Kingdom.Outcome{False{}, Kingdom.State{gold0, gold1, bank, owner, mortgaged, 0}} : Kingdom.Outcome}

law wrong_turn_repay1_rejected:
  for gold0: U32
  for gold1: U32
  for bank: U32
  for owner: U32
  for mortgaged: Bool
  {Kingdom.transition(Kingdom.State{gold0, gold1, bank, owner, mortgaged, 0}, Kingdom.Repay1{})
    == Kingdom.Outcome{False{}, Kingdom.State{gold0, gold1, bank, owner, mortgaged, 0}} : Kingdom.Outcome}
