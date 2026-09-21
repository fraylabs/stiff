# Native persistent store

Stiff's store is a bounded SQLite-backed key/value API for local application
state. It combines a versioned compare/write with a durable operation receipt in
one transaction. This supports safe process restart and explicit reconciliation
when a process dies after commit but before its caller receives the result.

It is a native Bend/C effect. Applications link SQLite dynamically and do not run
Node, Python, a daemon or a hosted service. `Store.open(path)` creates or validates
one filesystem database and returns a scoped `Store` value. It rejects `:memory:`
and does not install global state. The parent directory must already exist. Use a private application-owned directory;
filesystem permissions are the access boundary. A Store value is not a path sandbox.

```bend
import ../src/store.bend as Db

def use(result: Db.OpenResult) -> IO(Db.WriteResult):
  match result:
    case Db.StoreReady{store}:
      Db.Store.compare_write(store, "create-greeting-1", "greeting", 0, "hello")
    case Db.StoreOpenError{code, message}:
      IO.die(Db.WriteResult, 1, code)
```

The runnable [store example](../examples/store.bend) accepts a database path:

```sh
./scripts/build-native.sh examples/store.bend /tmp/stiff-store
/tmp/stiff-store /tmp/example.db
```

## API and transaction behavior

| Operation | Result |
| --- | --- |
| `Store.open(path)` | `StoreReady{store}` or `StoreOpenError{code, message}` |
| `Store.read(store, key)` | `StoreFound{version, value}`, `StoreMissing{}` or `StoreReadError` |
| `Store.compare_write(store, operation_id, key, expected, value)` | A committed result, an idempotency conflict or `StoreWriteError` |
| `Store.operation(store, operation_id)` | The durable outcome for reconciliation, `StoreOperationUnknown{}` or an error |

Expected version `0` means “create only if absent.” A positive version means
“replace only this version.” Successful writes increment the version. A mismatch
returns either `StoreVersionConflict{current_version, current_value}` or
`StoreMissingConflict{}`. The store records successful and rejected comparisons,
so repeating the exact operation ID and exact input returns the corresponding
`StoreReplayed...` result without running the mutation again.

An operation ID can name one input only. Reusing it with another key, expected
version or value returns `StoreIdempotencyConflict{}` and changes nothing. Keys
and operation IDs are 1–255 UTF-8 bytes. Values are at most 1 MiB. Paths are at
most 4 KiB. SQL statements are fixed and all caller data uses bound parameters.

Each effect opens a scoped SQLite connection with a five-second busy bound. The
database uses WAL journaling and `synchronous=FULL`. Startup checks ownership and
the complete private table shape before changing persistent journal mode. Reads
do not take an immediate transaction, although SQLite startup/validation and WAL
coordination can still briefly contend with another connection. `compare_write`
takes an immediate transaction, so writers serialize; a lock that remains busy
for five seconds returns `store_busy`. The transaction checks an existing operation
receipt, performs the versioned mutation, inserts its receipt and commits them
together. Concurrent writers therefore cannot both satisfy the same version comparison. These are
SQLite durability guarantees subject to the filesystem and hardware honoring
flushes; Stiff does not claim immunity to media failure.

## Restart and uncertain results

If a caller loses the result of `compare_write`, it must retain the operation ID
and original input. Call `Store.operation` first:

- `StoreOperationUnknown{}` means no committed receipt is present. The operation
  may be attempted with its original operation ID and input.
- A known outcome means the transaction committed. Repeating the exact call is
  safe and returns the complete replay result.
- `StoreIdempotencyConflict{}` means the supplied input differs; do not substitute
  it for the recorded operation.
- `store_commit_uncertain` means the commit acknowledgement itself failed. Close
  the failed workflow, reopen the store and reconcile by operation ID before any
  retry.

The receipt covers only the mutation inside this database. It does not make an
HTTP request, payment, email or other external effect atomic with SQLite. Record
intent and external provider identifiers, reconcile the external system using
its own idempotency contract, and then record the observed outcome. Never infer
that an external effect failed merely because this process stopped. Stiff does
not claim distributed exactly-once execution.

## Schema, recovery and errors

Stiff marks the database with a private application ID and schema version. It
initializes only a database with no application ID, no user version and no user
schema objects. A nonempty unowned file, a file owned by another application, an
unsupported version, extra private objects or a mismatched table shape is rejected
before persistent pragmas or schema are changed. The schema is internal;
applications do not receive an arbitrary SQL interface. For a live database, use
SQLite's backup API or the SQLite CLI's `.backup` command. A filesystem copy is
supported only after all writers are quiescent and every store connection has
closed; copying the database and WAL sidecars during live writes is not a
consistent-backup procedure. Reopening after normal termination or a process
kill invokes SQLite recovery before an operation proceeds.

Errors use stable codes and fixed messages that do not echo paths, keys or values.
Codes include `invalid_store_path`, `invalid_store_input`,
`store_input_too_large`, `store_busy`, `store_open`, `store_readonly`,
`store_full`, `store_corrupt`, `store_schema`, `store_io` and
`store_commit_uncertain`.

`test/test_store.py` compiles the actual Bend fixture and covers fresh-process
restart, identical and conflicting idempotency keys, version races across two
processes, lost acknowledgement, SIGKILL between operations, integrity recovery,
input bounds and SQL metacharacters. Constructor layouts remain pinned private
Bend 2.0.20 ABI and must be reverified on a compiler upgrade.
