import Base
import ./engine.bend as Kingdom

def status(accepted: Bool) -> String:
  match accepted:
    case True{}: "ok"
    case False{}: "error"

def render(accepted: Bool, state: Kingdom.State) -> String:
  match state:
    case Kingdom.State{gold0, gold1, bank, owner, mortgaged, turn}:
      status(accepted) ++ " " ++ U32.show(gold0) ++ " " ++ U32.show(gold1)
      ++ " " ++ U32.show(bank) ++ " " ++ U32.show(owner) ++ " "
      ++ U32.show(Bool.to_u32(mortgaged)) ++ " " ++ U32.show(turn)

def run(args: List<String>, state: Kingdom.State) -> IO(Unit):
  match args:
    case Nil{}: IO.pure(Unit, Unit{})
    case Con{text, tail}:
      +outcome = Kingdom.transition(state, Kingdom.parse(text))
      +next = Kingdom.outcome_state(outcome)
      do IO<Unit>:
        IO.print(render(Kingdom.outcome_accepted(outcome), next))
        run(tail, next)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args, Kingdom.initial())
