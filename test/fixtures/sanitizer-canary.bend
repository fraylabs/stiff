import Base

def Probe.check(mode: U32) -> IO(Unit):
  import "./sanitizer-canary.c"

def number(value: Maybe<&2, U32>) -> U32:
  match value:
    case Some{n}: n
    case None{}: 0

def run(args: List<String>) -> IO(Unit):
  match args:
    case Con{mode, tail}: Probe.check(number(U32.read(mode)))
    case Nil{}: Probe.check(0)

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    run(args)
