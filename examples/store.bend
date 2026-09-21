import Base
import ../src/store.bend as Db

def show(result: Db.WriteResult) -> IO(Unit):
  match result:
    case Db.StoreApplied{version}: IO.print("stored version " ++ U32.show(version))
    case Db.StoreReplayed{version}: IO.print("already stored version " ++ U32.show(version))
    case Db.StoreVersionConflict{current_version, current_value}:
      IO.print("version conflict at " ++ U32.show(current_version))
    case Db.StoreReplayedVersionConflict{current_version, current_value}:
      IO.print("same conflict already recorded at " ++ U32.show(current_version))
    case Db.StoreMissingConflict{}: IO.print("expected key is missing")
    case Db.StoreReplayedMissingConflict{}: IO.print("same missing-key conflict already recorded")
    case Db.StoreIdempotencyConflict{}: IO.die(Unit, 1, "operation ID was used for different input")
    case Db.StoreWriteError{code, message}: IO.die(Unit, 1, code)

def opened(result: Db.OpenResult) -> IO(Unit):
  match result:
    case Db.StoreReady{store}:
      IO.bind(Db.WriteResult, Unit,
        Db.Store.compare_write(store, "example-create-greeting", "greeting", 0, "hello"), show)
    case Db.StoreOpenError{code, message}: IO.die(Unit, 1, code)

def start(args: List<String>) -> IO(Unit):
  match args:
    case Con{path, Nil{}}: IO.bind(Db.OpenResult, Unit, Db.Store.open(path), opened)
    case other: IO.die(Unit, 2, "usage: store DATABASE")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    start(args)
