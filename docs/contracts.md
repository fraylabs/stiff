# Pure HTTP contracts

`src/contracts.bend` lets an application express request-to-response decisions as
pure, total Bend functions. `Decision<S, B>` contains the complete next application
state and a `Response<B>`: either `Reply{status, body}` or
`Error{status, code, allow}`. State and body are arbitrary Bend Data types.
No contract function imports IO, foreign code or an unsafe definition.

A `Route{id, method, pattern, protected, statuses}` declares metadata.
`dispatch(S, B, routes, method, path, valid, state, next)` selects a route and
calls a **pure** handler of type
`Route -> List<&2, Param> -> S -> Decision<S, B>`.
The handler can close over a decoded request or observations from prior effects.

```bend
import Base
import ./src/contracts.bend as C

def routes() -> List<&2, C.Route>:
  [C.Route{0n, "POST", "/counter", True{}, [200n, 401n]}]

def increment(route: C.Route, params: List<&2, C.Param>, state: Nat) -> C.Decision<Nat, String>:
  C.Decision{1n+state, C.Reply{200n, "incremented"}}

def decide(method: String, path: String, valid: Bool, state: Nat) -> C.Decision<Nat, String>:
  C.dispatch(Nat, String, routes(), method, path, valid, state, increment)

law no_credentials_no_increment:
  for +state: Nat
  {decide("POST", "/counter", False{}, state)
    == C.Decision{state, C.Error{401n, "unauthorized", Nil{}}} : C.Decision<Nat, String>}
def no_credentials_no_increment(state):
  {==}
```

Perform effects at the edge: decode input, validate credentials, obtain a storage
snapshot, evaluate the decision, atomically commit its state when appropriate,
and render its response. Never call an effectful handler before inspecting the
pure authorization decision. Never treat an arbitrary command inside a body as
permission to write: the returned **state** is the state covered by read laws.
A pure handler cannot hide a SQLite call.

## Policies and laws

[CONTRACTS_PROOF.bend](../src/CONTRACTS_PROOF.bend) supplies universal laws,
included by Stiff's normal `src/PROOF.bend` gate:

| Law | Quantified guarantee |
| --- | --- |
| `protected_denies` | For any state/body types, state and pure continuation, protected + invalid returns exactly 401/unauthorized, empty Allow and unchanged state |
| `protected_route_denies` | Same guarantee for any selected protected route, route metadata, parameters, read flag and handler |
| `read_preserves` | Any proposed decision is returned with its original complete state when the read flag is True |
| `dispatch_read_preserves` | For any selection, credentials, state and handler, read-mode dispatch preserves complete state |
| `get_is_read`, `head_is_read` | Exact uppercase GET and HEAD enable that read policy |
| `unknown_is_404` | A Missing selection returns exactly 404/not_found with unchanged state and empty Allow, for any handler |
| `wrong_method_is_405` | A WrongMethod selection returns exactly 405/method_not_allowed with unchanged state and precisely its method list |

Status declarations are **claims to prove**, not runtime coercion.
`declared(B, route, response)` independently observes the actual response status
and tests membership in the route's declared status list. Write an application
law asserting it is True for every input to your handler. A wrong status then
invalidates the proof; it is not replaced by a success status. Include 401 in
protected route declarations. Router 404/405 are separate from matched-handler
status declarations.

The [ledger HTTP laws](../examples/ledger/HTTP_PROOF.bend) show how to prove
response bodies and declared statuses. `replay_response` quantifies over every
state and supplied original operation and checks the whole returned response,
including its Replayed constructor and original operation. `transfer_status_declared`
covers every engine outcome and operation, using the same transfer route
declaration that appears in the routing table. Other laws exercise the real
table's protected accounts, unknown path and wrong method, and GET/HEAD state
preservation even with a handler that proposes zeroing the balances.

## Routing and the edge

Routes use case-sensitive methods and raw slash-delimited paths with `:name`
parameters, matching the existing Router conventions. First matching method/path
wins. Methods for a known path are deduplicated with the existing Router's
suffix-first collection rule: repeated methods retain their last occurrence's
position. 405 carries that list. Render it as an Allow header (the ledger uses
`App.allowed`).
HEAD requires an explicit route; GET does not register HEAD. Protection applies
to selected routes; unknown paths and wrong methods still get 404/405 before
handler authorization. Credentials are a caller-supplied Bool, not a credential
validation system.

The pure contracts matcher and selector now agree universally with the
independent [routing specification](../src/routing_spec.bend). The
[routing proofs](../src/ROUTING_PROOF.bend) are imported by
`CONTRACTS_PROOF.bend`, so both the framework and example gates check them.
These are structural proofs for **arbitrary finite route tables, methods,
patterns and paths**, not bounded tables or sampled cases. Route IDs, protection
flags, status lists and captured parameters are retained exactly.

The specification first matches raw `/`-separated segments, then filters the
table into path hits in declaration order. A literal segment must equal the raw
segment. A segment beginning with `:` captures only if both its remaining name
and the path segment are non-empty. Empty literal segments match empty segments;
leading, repeated and trailing slashes are significant. Captures retain pattern
order, including repeated parameter names. No percent-decoding, case folding,
query parsing or normalization occurs here. `String.split`, `String.eq` and
character equality are trusted Base semantics.

Two separate specification observations find the first exact method hit and
collect all path-hit methods, dropping any verb already present in the suffix.
Their summary is Found for the first method hit, Missing for no path hits, and
WrongMethod otherwise with exactly that last-occurrence method order. The proof
connects the implementation's recursive selection to this two-observation
specification; the specification calls no contracts matching or selection helper.

| Routing law | Quantified guarantee |
| --- | --- |
| `values_match_spec` | For any two segment lists, the complete Match equals the segment specification, including failure and exact captures |
| `match_path_matches_spec` | Same equality for every pair of raw strings split at `/`; soundness and completeness follow from full Match equality |
| `membership_matches`, `unique_matches`, `allowed_matches` | Implementation method membership, duplicate handling and suffix collection agree with the specification for arbitrary lists and suffix selections |
| `resolve_matches_summary`, `select_matches_spec` | Complete Selection equals first-method-hit plus independently collected Allow methods, for any table/method/path; pins down all three constructors and their fields |
| `selected_first` | Given the specification's first method hit, select returns precisely that route and its parameters |
| `missing_no_hits` | Given no specification path hits, select returns Missing |
| `missing_iff_no_path` | Missing's constructor observation is True if and only if the specification path-hit list is empty, for any table/method/path |
| `wrong_method_exact_allow` | Given non-empty specification path hits and no method hit, select returns WrongMethod with exactly the specification's allowed list |
| `wrong_method_iff` | WrongMethod's constructor observation is True if and only if there are path hits and no specification method hit, for any table/method/path |
| `dispatch_unknown` | Under the no-path-hit premise, arbitrary-table dispatch returns exactly 404/not_found, unchanged state and empty Allow |
| `dispatch_wrong_method` | Under the known-path/no-method-hit premises, arbitrary-table dispatch returns exactly 405/method_not_allowed, unchanged state and the specification's Allow list |
| `dispatch_protected` | If the specification's first method hit is protected, invalid credentials return exactly 401/unauthorized, unchanged state and empty Allow for any handler |

The conditional laws' premises describe independent observations of the actual
table and request, rather than assuming the implementation's Selection result.
The unconditional `select_matches_spec` covers all cases, including the reverse
directions: Missing exactly when no pattern matches, and WrongMethod exactly
when at least one pattern matches but no method does.

`make routing-mistakes` checks four ordinary well-typed mutations against the
universal proofs **and** a false concrete law instance. A proof rejection alone
can mean that a proof needs updating; the witness demonstrates incorrect behavior.
No mutant executable is emitted.

| Mistake | Rejected witness |
| --- | --- |
| Treat lowercase `get` as `GET` | `case_sensitive_method`: returns Found instead of WrongMethod |
| Capture an empty path segment | `empty_capture_rejected`: `/x/:id` must reject `/x/` |
| Let the last method/path hit win | `first_route_wins`: the first parameter route must win over a later exact route |
| Prepend duplicate Allow methods | `allow_last_occurrence_order`: GET, POST, GET must produce POST, GET |

The existing effectful `Router` API has the same documented semantics but is a
separate implementation; no universal refinement proof connects its handler
registry to these Data-only contracts. Its native routing tests remain necessary.
The raw HTTP parser, request-to-table adapter and Allow-header serialization also
remain tested edges. The ledger and bookings supply concrete application-table
proofs and native routing tests in addition to these framework laws.

[Routing verification evidence](evidence/routing-verification.json) records all
34 routing laws/lemmas, accepted compiler and independent kernel verdicts, the
four mutation failures and both examples' passing check/mistakes/test/verdict
gates. The full local suite had 145 passes, one opt-in consumer-setup skip and
one RSS benchmark failure because process-memory inspection was unavailable;
its semantic benchmark phases and shutdown passed. No checker limitation or
implementation bug was found in this proof work.

The [bookings example](../examples/bookings) applies the same contracts to room
schedules: no double booking, exact cancellation, retry state equality, read
preservation, admin denial and declared statuses. Its independent specification
uses half-open intervals and its mutation demo includes enclosing-slot and
wrong-room bugs. The [standalone starter](../templates/proven-api/README.md),
generated with `make new NAME=myapi DIR=../myapi`, checks both framework and
application laws before building.

The compiler checks supplied proofs, not all possible promises automatically.
A build must explicitly check its proof entry point and require the verdict text
`ALL PROOFS CHECK` without `SOME PROOFS FAIL` or `Error:`. Compiling the effectful
entry point alone bypasses that gate. `make -C examples/ledger build` runs both
framework and application gates. Its optional `verdict` also checks these laws
with the existing scoped independent BendTT kernel.

Proofs cover the pure decisions. Credential validation, decoding, selection of
the original stored operation, serialization, committing the returned state,
SQLite concurrency/durability, native effects, transport fallbacks and process
failures are trusted/tested edges. In particular, a response encoder can still
fail or a server can reject a request before dispatch. A pure status law does
not prove every byte emitted by a socket has that status. Stiff does not claim
end-to-end verification, an authentication system or memory safety.
