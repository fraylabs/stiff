# Rooms fill. Slots don't collide.

A native room-booking HTTP API on **Stiff + Bend 2.0.35**. Rooms 0, 1 and 2
have half-open slots `[start, end)`: a booking ending at 20 and another starting
at 20 fit together. An enclosing slot conflicts even if its start is outside
the existing booking. Different rooms can use the same time.

The pure engine proves **no double booking after any accepted booking**, for
arbitrary schedules, key lists and natural-number requests. It checks the whole
candidate schedule, so this theorem needs no assumption that the input was
already safe. Rejected requests preserve the complete state. Cancellation
removes exactly the named ID and keeps the retry keys. The same key twice
equals once; cancelling the same ID twice also equals once. [Exact laws and limits](PROOFS.md).

## Try it in two minutes

With Stiff's pinned compiler and native dependencies already available:

```sh
make -C examples/bookings check       # require ALL PROOFS CHECK
make -C examples/bookings mistakes    # six valid programs; six failing law instances
make -C examples/bookings run         # loopback :8080, SQLite persists across restart
```

In another terminal:

```sh
curl -s http://127.0.0.1:8080/bookings
# {"version":1,"replayed":false,"bookings":[]}
curl -s http://127.0.0.1:8080/bookings -H 'Content-Type: application/json' \
  -d '{"idempotency_key":1,"expected_version":1,"room":0,"start":10,"end":20}'
# {"version":2,"replayed":false,"bookings":[{"id":1,"room":0,"start":10,"end":20}]}
```

Repeat the POST: `replayed:true`, one booking. Try room 0, slot [15,25), key 2,
version 2: HTTP 422, unchanged schedule. Slot [20,30) with that same fresh key
and version succeeds. A rejected slot reserves no key. Read the current version
before a new request; keep the exact request/key when retrying an uncertain one.

Cancellation uses a separate operation-key namespace and a **public demo gate**:

```sh
curl -s http://127.0.0.1:8080/admin/cancellations \
  -H 'Content-Type: application/json' -H 'X-Demo-Access: allowed' \
  -d '{"idempotency_key":1,"expected_version":2,"id":1}'
```

Without that header: 401 before storage access. It is a fixed public value,
not a login system. Cancelled booking keys stay remembered: a booking retry
cannot bring the cancelled slot back. Cancelling an absent ID succeeds with
the schedule unchanged; the adapter still commits its cancellation receipt.

## Try the mistakes

`make mistakes` copies pure sources into `.cache/bookings/mistakes` and applies
one independent [patch](mistakes/) at a time. All six ordinary programs check.
Each fails the generic proof gate **and** a concrete instance of the intended
law; no mutant binary is built and shipped sources stay untouched.

| Mistake | False law / concrete instance | Result |
| --- | --- | --- |
| Closed rather than half-open overlap | `overlap_matches_half_open` / `half_open_boundary` | Caught |
| Check only the requested start | `overlap_matches_half_open` / `enclosing_slot_rejected` | Caught |
| Check other rooms instead of this room | `overlap_matches_half_open` / `same_room_rejected` | Caught |
| Cancel ID + 1 | `remove_exact` / `cancel_exact_instance` | Caught |
| Append again on retry | `same_key_twice_equals_once` / `retry_once_instance` | Caught |
| Let a GET handler's proposed write escape | `get_does_not_write` / `get_no_write_instance` | Caught |

The closed-interval bug over-rejects valid adjacent slots; no-double-booking
alone would miss it. The separate half-open semantics law catches it.
A generic proof can also fail because a changed implementation invalidates
its supplied proof even when its statement stays true. The concrete law
instances show an actual false promise, rather than just a broken proof.
[Recorded diagnostics](evidence/mutations.json) include both verdicts.

## Where the proof stops

[Pure HTTP contracts](../../docs/contracts.md) enforce GET/HEAD modeled-state
preservation for any pure handler and deny the protected admin route without
credentials. Handler status laws cover every engine outcome/request and each
route's actual declaration, including the admin denial. Router 404/405 are
separate. These laws cover pure decisions, not every response byte on the socket.

SQLite compares and commits the complete schedule, retained keys and canonical
request receipts as one versioned snapshot. Concurrent writers cannot both
commit against the same version. Race, restart and independently calculated
history checks exercise this edge; **SQLite and effects are tested, not proven**.
A conflicting version is 409. A retained key with changed fields is 409.
Successful booking and cancellation receipts share a 1,000-operation limit.
Slots are integer minutes 0–1440 in one abstract day; booking IDs/operation keys
are 1–1,000,000. This is a bounded loopback demonstration.

Decoding, persisted receipt selection, credential validation, serialization,
committing the modeled state, SQLite concurrency/durability, native C effects,
libevent, json-c, compiler/runtime and OS remain trusted. The model uses
unbounded inductive naturals; the native adapter deliberately bounds inputs.
No calendar, timezone, authentication, receipt compaction or production-readiness
claim. A missing or failed acknowledgement must be reconciled by reading the
schedule and retrying the **same** request; a missing booking may also mean it
was subsequently cancelled. There is no automatic retry or separate operation
receipt endpoint in this example.

`make check mistakes test` checks the framework and application gates and
native API. `make verdict` uses the ledger's existing scoped independent kernel
(or `BENDTT`); it succeeded with `ALL PROOFS CHECK`. Bend-to-BendTT translation
is still trusted. Build/setup tests share the ledger's parent-directory
`.heavy.lock`; no fresh dependency setup occurs here. Python is tooling only.
MIT; the running service is a native executable.
