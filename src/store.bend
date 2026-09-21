import Base

# A Store is a scoped filesystem database. Opening it initializes or validates
# Stiff's private schema; no process-global service or connection is installed.
type Store is Data:
  Store{path: String}

type OpenResult is Data:
  StoreReady{store: Store}
  StoreOpenError{code: String, message: String}

type ReadResult is Data:
  StoreFound{version: U32, value: String}
  StoreMissing{}
  StoreReadError{code: String, message: String}

# A replay is the durable result of the same operation ID and identical input.
# Reusing an operation ID with different input is an idempotency conflict.
type WriteResult is Data:
  StoreApplied{version: U32}
  StoreReplayed{version: U32}
  StoreVersionConflict{current_version: U32, current_value: String}
  StoreReplayedVersionConflict{current_version: U32, current_value: String}
  StoreMissingConflict{}
  StoreReplayedMissingConflict{}
  StoreIdempotencyConflict{}
  StoreWriteError{code: String, message: String}

# Operation lookup is the reconciliation path after a caller loses a result.
# Retry compare_write with exactly the same input to recover the complete result.
type OperationResult is Data:
  StoreOperationApplied{key: String, version: U32}
  StoreOperationVersionConflict{key: String, current_version: U32}
  StoreOperationMissingConflict{key: String}
  StoreOperationUnknown{}
  StoreOperationError{code: String, message: String}

def Store.open(path: String) -> IO(OpenResult):
  import "./effects/store.c"

def Store.read(+store: Store, key: String) -> IO(ReadResult):
  import "./effects/store.c"

# expected_version 0 creates an absent key. A positive version replaces only
# that exact version. The write and its operation receipt commit atomically.
def Store.compare_write(+store: Store, operation_id: String, key: String,
                        expected_version: U32, value: String) -> IO(WriteResult):
  import "./effects/store.c"

def Store.operation(+store: Store, operation_id: String) -> IO(OperationResult):
  import "./effects/store.c"
