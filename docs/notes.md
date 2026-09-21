# Persistent notes application

[examples/notes.bend](../examples/notes.bend) combines parameter routes, nested
schemas, request observability and the native SQLite store in a runnable local
HTTP application. It binds only to `127.0.0.1`. It is a single-workspace example,
not a user/account or authentication system. Put an authenticated gateway in
front of it before making it remotely accessible.

```sh
make setup
./scripts/build-native.sh examples/notes.bend .cache/native/notes
mkdir -m 700 .cache/notes-state
make runner
.cache/native/stiff-run --grace-ms 6000 -- \
  .cache/native/notes --threads 2 .cache/notes-state/notes.db 8080
```

The directory is application-owned. No services or global database are installed.
Python is only used to build/test; the running application is native Bend/C with
SQLite. The accept loop passes the runtime store explicitly to concurrent
handlers and uses the standard dispatch/finish lifecycle.

Create a note using an operation ID chosen and retained by the caller:

```sh
curl -sS -X PUT http://127.0.0.1:8080/notes/first \
  -H 'Content-Type: application/json' \
  --data '{"operation_id":"create-first","expected_version":0,"note":{"title":"Try Stiff","done":false,"tags":["native"]}}'
# {"version":1,"replayed":false}
curl -sS http://127.0.0.1:8080/notes/first
# {"version":1,"note":{"title":"Try Stiff","done":false,"tags":["native"]}}
```

`PUT /notes/:id` replaces the whole note. Use expected version `0` to create and
the last read positive version to update. A new mutation needs a new operation ID.
Concurrent mutations using the same expected version have one winner; the other
gets HTTP 409. Repeating the exact successful mutation returns its original
version and `replayed:true`, including after restart. Reusing an operation ID with
different input gets `idempotency_conflict` and changes nothing. IDs are scoped
to this database, not to one URL. Preserve the original note fields and their
order for a retry: the store compares the serialized value bytes, not semantic
JSON equivalence. Optional tags omitted and tags present as `[]` are different inputs.

If a response is lost, query its receipt before deciding what to do:

```sh
curl -sS http://127.0.0.1:8080/operations/create-first
# {"state":"applied","key":"first","version":1}
```

A receipt can also record `version_conflict` or `missing_conflict`. HTTP 404 with
`operation_unknown` means no committed receipt was found; a concurrent write
may still be in progress. Retrying the *same* ID and exact input is safe within
SQLite's transaction contract. Never use a different operation ID to retry an
uncertain mutation. This application makes no external writes and does not claim
distributed exactly-once behavior.

Routes:

| Method/path | Behavior |
| --- | --- |
| `GET /health` | Liveness (`{"status":"ok"}`), not a database readiness guarantee |
| `GET /metrics` | Native transport/lifecycle counters and gauges |
| `GET /notes/:id` | Current version and note, or 404 |
| `PUT /notes/:id` | Validated version comparison and durable operation receipt |
| `GET /operations/:id` | Reconcile a durable write outcome, or 404 |

Path and operation IDs contain 1–63 Unicode scalars, ensuring they fit the store's
255-byte key/operation limit even with four-byte UTF-8 scalars. The path router
retains raw URL encoding and does not decode `%2F`. Titles contain 1–80 scalars, `done` is a required
boolean, and optional tags contain at most eight strings of 1–24 scalars each.
Objects reject unknown fields. Expected versions range from 0 to 4,294,967,294;
the store reserves room for the next version increment.
Malformed JSON gets HTTP 400; schema errors get 422 with a field path; missing
routes and wrong methods get 404/405, with `Allow` for 405. Errors use the shared
`{"error":{"code":...,"message":...}}` envelope, with extra validation/conflict
fields where relevant. Store failures use 503 and a stable store code; reconcile
uncertain commits before retrying.

Application responses include `x-request-id`. `App.observe` records structured
handler outcomes; the supervisor provides bounded best-effort stderr delivery.
Neither logs nor `/health` prove a write committed: the durable receipt does.
Stop with SIGTERM and retain the database for restart. Back up via SQLite's backup
API, or copy only after all writers have stopped; do not copy a live database
without its consistency protocol. [The store contract](store.md) details recovery.

[The deployment unit](../examples/deploy/notes.service) shows Linux cgroup memory
and CPU limits with a private state directory. It is an example, not an installed
service. [Execution limits](execution.md) distinguish cooperative handler checks,
process cancellation and the Linux resident-memory boundary.

`test/test_notes.py` runs the compiled application outside the checkout without
build tools on PATH. It verifies create/update/restart, schema and transport
errors, concurrent version races, identical/conflicting retries, lost HTTP
acknowledgements followed by SIGKILL/restart/reconciliation, and observability.
