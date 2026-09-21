import Base
import ./LAWS.bend as Laws
import ./engine.bend as Kingdom

def Laws.initial_state_exact():
  {==}

def Laws.invalid_is_identity(state):
  match state:
    case Kingdom.State{gold0, gold1, bank, owner, mortgaged, turn}:
      {==}

def Laws.pass0_changes_only_turn(gold0, gold1, bank, owner, mortgaged):
  {==}

def Laws.pass1_changes_only_turn(gold0, gold1, bank, owner, mortgaged):
  {==}

def Laws.wrong_turn_buy0_rejected(gold0, gold1, bank, owner, mortgaged):
  {==}

def Laws.wrong_turn_mortgage0_rejected(gold0, gold1, bank, owner, mortgaged):
  {==}

def Laws.wrong_turn_repay0_rejected(gold0, gold1, bank, owner, mortgaged):
  {==}

def Laws.wrong_turn_buy1_rejected(gold0, gold1, bank, owner, mortgaged):
  {==}

def Laws.wrong_turn_mortgage1_rejected(gold0, gold1, bank, owner, mortgaged):
  {==}

def Laws.wrong_turn_repay1_rejected(gold0, gold1, bank, owner, mortgaged):
  {==}
