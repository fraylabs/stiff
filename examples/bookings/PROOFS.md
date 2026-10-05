# Exact booking contracts

The model is `State{bookings, keys}`, with `Booking{id, room, start, end}`.
All fields are natural numbers. `book(state, key, room, start, end)` uses the key
as the booking ID. Arbitrary input states need not have unique IDs, valid slots
or safe schedules. A fresh accepted request requires a room below 3 and start
less than end, and validates pairwise safety of the **whole** proposed list.
Duplicate keys return Replayed with unchanged state before validation.

[spec.bend](spec.bend) independently observes the output fields. Its overlap
predicate is precisely `same room && a.start < b.end && b.start < a.end`.
`safe` checks each booking against all later bookings. The engine has its own
implementation; proofs connect it to these fixed observations. The observations
are not patched by the mistake harness.

## Universal engine laws

[ENGINE_PROOF.bend](ENGINE_PROOF.bend) contains constructive proofs with no
holes or unfilled claims. The headline statements quantify over all modeled
states and requests, without bounded enumeration:

| Law | Exact guarantee |
| --- | --- |
| `no_double_booking` | If the actual book outcome is Applied, its complete returned booking list is pairwise nonoverlapping within each room; Rejected/Replayed impose no safety condition |
| `rejected_request_unchanged` | If the actual book outcome is Rejected, its complete returned state equals the input, including keys |
| `cancelling_removes_exactly` | For every list, key list and ID, cancellation returns exactly the stable filter excluding that ID, with keys unchanged |
| `cancellation_twice_equals_once` | Cancelling the same ID twice equals once for every complete state |
| `same_key_twice_equals_once` | Applying the same book request to its own returned state equals the first returned complete state, including rejection and replay branches |
| `overlap_matches_half_open` | The actual engine overlap decision equals the independent half-open same-room specification for every pair of bookings |

For arbitrary malformed states containing repeated IDs, cancellation removes
**all** occurrences of that ID. The native adapter creates IDs from fresh
retained booking keys, so ordinary reachable states have unique booking IDs.
The filter theorem preserves every other booking's fields and relative order.
Keys are retained after cancellation; retry cannot recreate a cancelled booking.
Idempotency means equal modeled state, not equal response bytes. A rejected key
is not retained, and may succeed after an intervening state change. Engine
replay ignores changed request fields; the tested HTTP adapter compares canonical
persisted inputs and rejects changed fields.

The remaining engine laws are constructive lemmas:
`compatible_matches`, `safe_matches`, `finish_safe`, `checked_safe`,
`dispatch_safe`, `finish_rejection`, `checked_rejection`,
`dispatch_rejection`, `keep_matches`, `remove_exact`, `key_reflexive`,
`remembered_key`, `finish_retry`, `checked_retry`, `dispatch_retry`,
`remove_step_retry`, `remove_retry`.
The safety/retry helper premises connect actual checker results and the real
first request to their branches; the top-level proofs supply those equalities.
They are not assumptions about arbitrary callers or axioms.

## Universal HTTP laws and concrete routing laws

[HTTP_PROOF.bend](HTTP_PROOF.bend) checks:

| Law | Guarantee |
| --- | --- |
| `booking_status_declared` | For every engine outcome, the complete response's status is in the actual POST /bookings declaration |
| `booking_handler_status_declared` | Same membership for every request and state, including a mismatched request constructor |
| `cancellation_status_declared` | For every request and state, the actual cancellation handler's status is declared |
| `admin_response_status_declared` | Membership for every request, state and credential Bool, including 401 |
| `read_status_declared`, `head_status_declared` | Read handlers/HEAD decisions always return a declared status, for every state and request |
| `admin_denied` | For every state/request, invalid credentials on the actual admin route return exactly unchanged state and 401/unauthorized |
| `get_does_not_write`, `head_does_not_write` | Actual table's GET/HEAD preserves complete state for **any** pure handler, even one proposing writes |
| `access_denied_before_effects` | Actual admin access plan without credentials contains 401 and no Execute |
| `unknown_route` | Concrete GET /absent is exactly 404/not_found |
| `wrong_method` | Concrete DELETE /bookings is 405 with exactly [GET, HEAD, POST] |

The eight framework contracts laws are also imported by the application gate.
They quantify over arbitrary state/body types, pure handlers and selected routes.
Selection/path matching has concrete tests here, not a universal correctness
proof. Status declarations include the tested adapter's 400/409/500/503 errors;
the pure laws do not verify those effectful error paths or transport fallbacks.

## Verification and trusted edge

`make build` requires accepted framework and application verdicts before
compilation. Exit 0 alone is insufficient: `ALL PROOFS CHECK` must appear and
`SOME PROOFS FAIL`/`Error:` must be absent. Directly compiling the effectful
entry point bypasses this gate. `make mistakes` checks ordinary programs and
both generic and concrete law verdicts. It does not build mutant binaries.

The independent BendTT kernel accepted the exported new engine and HTTP laws,
plus framework contracts laws. Translation into BendTT, Base semantics,
Bend compilation/runtime and native ABI remain trusted. Native tests independently
calculate schedules, test adjacency/enclosures, authorization, GET/HEAD,
canonical retries, cancellation, restart/SIGKILL and version/identical-key races.
They execute the binary without tools on PATH. This is not a formal proof of
SQLite, persistence, concurrency, credential validation, decoding/encoding,
receipt selection, effect execution, native memory safety or HTTP transport.

The HTTP adapter enforces integer domain bounds and rejects stored overlapping
schedules. Its receipt schema is structural; the pure theorem does not establish
that persisted receipts/keys/IDs have the intended provenance. The trusted
edge must supply the intended state and request and commit exactly the returned
state. No end-to-end verification claim is made.
