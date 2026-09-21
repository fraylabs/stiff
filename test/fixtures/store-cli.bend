import Base
import ../../src/store.bend as Db

def show_write(result: Db.WriteResult) -> IO(Unit):
  match result:
    case Db.StoreApplied{version}: IO.print("applied:" ++ U32.show(version))
    case Db.StoreReplayed{version}: IO.print("replayed:" ++ U32.show(version))
    case Db.StoreVersionConflict{current_version, current_value}:
      IO.print("conflict:" ++ U32.show(current_version) ++ ":" ++ current_value)
    case Db.StoreReplayedVersionConflict{current_version, current_value}:
      IO.print("replayed-conflict:" ++ U32.show(current_version) ++ ":" ++ current_value)
    case Db.StoreMissingConflict{}: IO.print("missing-conflict")
    case Db.StoreReplayedMissingConflict{}: IO.print("replayed-missing-conflict")
    case Db.StoreIdempotencyConflict{}: IO.print("idempotency-conflict")
    case Db.StoreWriteError{code, message}: IO.die(Unit, 1, code)

def show_read(result: Db.ReadResult) -> IO(Unit):
  match result:
    case Db.StoreFound{version, value}:
      IO.print("found:" ++ U32.show(version) ++ ":" ++ value)
    case Db.StoreMissing{}: IO.print("missing")
    case Db.StoreReadError{code, message}: IO.die(Unit, 1, code)

def show_operation(result: Db.OperationResult) -> IO(Unit):
  match result:
    case Db.StoreOperationApplied{key, version}:
      IO.print("operation-applied:" ++ key ++ ":" ++ U32.show(version))
    case Db.StoreOperationVersionConflict{key, current_version}:
      IO.print("operation-conflict:" ++ key ++ ":" ++ U32.show(current_version))
    case Db.StoreOperationMissingConflict{key}:
      IO.print("operation-missing-conflict:" ++ key)
    case Db.StoreOperationUnknown{}: IO.print("operation-unknown")
    case Db.StoreOperationError{code, message}: IO.die(Unit, 1, code)

def write_parsed(+store: Db.Store, operation: String, key: String,
                 value: String, parsed: Maybe<&2, U32>) -> IO(Unit):
  match parsed:
    case Some{expected}:
      IO.bind(Db.WriteResult, Unit,
        Db.Store.compare_write(store, operation, key, expected, value), show_write)
    case None{}: IO.die(Unit, 2, "invalid expected version")

def write(+store: Db.Store, operation: String, key: String,
          expected_text: String, value: String) -> IO(Unit):
  write_parsed(store, operation, key, value, U32.read(expected_text))

def uncertain_show(result: Db.WriteResult) -> IO(Unit):
  do IO<Unit>:
    IO.sleep(30000)
    show_write(result)

def uncertain_parsed(+store: Db.Store, operation: String, key: String,
                     value: String, parsed: Maybe<&2, U32>) -> IO(Unit):
  match parsed:
    case Some{expected}:
      IO.bind(Db.WriteResult, Unit,
        Db.Store.compare_write(store, operation, key, expected, value), uncertain_show)
    case None{}: IO.die(Unit, 2, "invalid expected version")

def uncertain(+store: Db.Store, operation: String, key: String,
              expected_text: String, value: String) -> IO(Unit):
  uncertain_parsed(store, operation, key, value, U32.read(expected_text))

def after_pause(+store: Db.Store, ignored: Unit) -> IO(Unit):
  IO.bind(Db.WriteResult, Unit,
    Db.Store.compare_write(store, "between-second", "between-b", 0, "second"), show_write)

def first_done(+store: Db.Store, result: Db.WriteResult) -> IO(Unit):
  do IO<Unit>:
    shown : Unit <- show_write(result)
    IO.sleep(30000)
    after_pause(store, shown)

def between(+store: Db.Store) -> IO(Unit):
  IO.bind(Db.WriteResult, Unit,
    Db.Store.compare_write(store, "between-first", "between-a", 0, "first"), first_done(store))

def run(+store: Db.Store, mode: String, args: List<String>) -> IO(Unit):
  match mode:
    case "read":
      match args:
        case Con{key, Nil{}}: IO.bind(Db.ReadResult, Unit, Db.Store.read(store, key), show_read)
        case other: IO.die(Unit, 2, "read expects key")
    case "operation":
      match args:
        case Con{operation, Nil{}}:
          IO.bind(Db.OperationResult, Unit, Db.Store.operation(store, operation), show_operation)
        case other: IO.die(Unit, 2, "operation expects id")
    case "write":
      match args:
        case Con{operation, Con{key, Con{expected, Con{value, Nil{}}}}}:
          write(store, operation, key, expected, value)
        case other: IO.die(Unit, 2, "write expects id key version value")
    case "uncertain":
      match args:
        case Con{operation, Con{key, Con{expected, Con{value, Nil{}}}}}:
          uncertain(store, operation, key, expected, value)
        case other: IO.die(Unit, 2, "uncertain expects id key version value")
    case "between": between(store)
    case other: IO.die(Unit, 2, "unknown mode")

def opened(mode: String, args: List<String>, result: Db.OpenResult) -> IO(Unit):
  match result:
    case Db.StoreReady{store}: run(store, mode, args)
    case Db.StoreOpenError{code, message}: IO.die(Unit, 1, code)

def start(args: List<String>) -> IO(Unit):
  match args:
    case Con{mode, Con{path, rest}}:
      IO.bind(Db.OpenResult, Unit, Db.Store.open(path), opened(mode, rest))
    case other: IO.die(Unit, 2, "expected mode path")

def main() -> IO(Unit):
  do IO<Unit>:
    args : List<String> <- IO.args()
    start(args)
