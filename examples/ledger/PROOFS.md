# Exact contract and proof boundary

The model is two fixed accounts (`alice`, `bob`), natural-number balances, a list
of retained numeric keys, and a direction. `E.transfer(state, key, direction,
amount)` returns a status plus a new state. The fixed [specification observations](spec.bend) inspect the actual returned fields; the laws do not let the accounting implementation redefine total or rejection. The four headline laws quantify over
**every** well-typed engine state, key, direction and amount. They are not bounded
enumerations or sampled tests. The HTTP limits (200 total cents, numeric keys
1–1,000,000 and at most 1,000 successful receipts) belong to the adapter.

`move` recursively moves one unit from the source to the destination. Running
out of source returns `NoFunds`, discarding partial work. `finish` then returns
the original state, or constructs both new balances and retains the key. `seen`
and `dispatch` prevent another application of a retained key. All of these are
pure, terminating Bend definitions with no foreign effects or `@unsafe`.

## Laws accepted by the checker and independent kernel

See [LAWS.bend](LAWS.bend) for actual quantifiers and equations, and
[PROOF.bend](PROOF.bend) for the constructive proofs. There are 27 laws in LAWS
plus the local `add_zero` arithmetic lemma in PROOF. No open claims or proof
holes are accepted by the gate. The build/check gate also keeps Stiff's
`src/PROOF.bend` request-policy laws in its checks.

| Law | Exact guarantee |
| --- | --- |
| `transfer_conserves` | Total of the returned state equals total of the input state, including acceptance, rejection and replay |
| `transfer_nonnegative` | Both returned balances are ≥ 0 in the natural-number model |
| `rejected_transfer_unchanged` | If the returned status is `Rejected`, its complete state equals the input; accepted/replayed branches impose no additional equality via this observation |
| `same_key_twice_equals_once` | Transfer on its own returned state, with the same key/direction/amount, equals the first returned state, including the key list |
| `alice_exact_debit_credit` | A fresh transfer of `amount` from `amount + remainder` leaves Alice at `remainder`, Bob at `amount + bob`, status Applied, and key prepended to the previous complete list |
| `bob_exact_debit_credit` | Symmetric exact fresh transfer, preserving account identities |
| `alice_overdraft_rejected` | A fresh transfer of Alice's balance + 1 + any extra rejects with the original complete state |
| `bob_overdraft_rejected` | Symmetric overdraft rejection |
| `remembered_key_preserves_state` | A key at the head of any prior key list preserves the whole state for any new amount/direction |
| `move_conserves` | Successful movement preserves source + destination; NoFunds uses the unchanged total as its observation |
| `insufficient_funds` | Movement of source + 1 + extra returns NoFunds |
| `exact_movement` | Movement from amount + remainder returns remainder and amount + destination |
| `finish_conserves` | Finish's total matches the movement total (or original total on NoFunds) |
| `fresh_conserves` | Fresh transfer total is unchanged |
| `dispatch_conserves` | Both duplicate and fresh branches preserve total |
| `finish_rejection_identity` | Finish's rejected-state observation equals the original state |
| `dispatch_rejection_identity` | Both dispatch branches' rejected-state observations equal the original state |
| `finish_retry` | Given an equality connecting finish to the real first transfer, transferring the finished state again preserves it; the premise is supplied by proofs, not an axiom |
| `dispatch_retry` | Given the actual seen-key result, transferring the dispatch result again preserves that state |
| `nat_nonnegative` | Every natural number is ≥ 0 |
| `balances_nonnegative` | Every well-typed engine State has nonnegative balances |
| `key_equals_itself` | Natural-number key equality is reflexive |
| `remembered_key` | Membership of a key prepended to any key list is True |
| `add_successor` | a + (1 + b) = 1 + (a + b) |
| `add_commutes` | a + b = b + a |
| `initial_state_exact` | Initial state is exactly 100 cents per account, empty key list |
| `initial_supply` | Initial total is 200 cents |
| `add_zero` (local) | a + 0 = a |

Negative balances are excluded by the representation, and this makes the
nonnegative theorem easy. It alone would not stop a clamped overdraft from
creating money. Conservation, insufficient-funds and exact-movement laws supply
those missing constraints. Rejection identity includes receipts: it cannot both
leave the *complete* state unchanged and insert a rejected key. Keys are retained
on success only. Idempotency does not say a rejected request can never succeed
after intervening transfers, or that a replay has identical status/HTTP bytes.
The new HTTP laws separately reject the status-label mutant; the engine laws
continue to describe state, not response bytes.

## What mutation rejection means

The compiler checks the supplied proof; it does not automatically discover a
counterexample. A changed implementation can invalidate a proof even when its
statement remains true. For example, double-apply first fails the frozen
`dispatch_conserves` proof, although a repeated balanced transfer still conserves
money; the real false rule is idempotency. Reversing accounts similarly invalidates
a `finish_conserves` proof while retaining the total. The mutation harness also
checks a concrete instance of the intended rule, using fixed specification
observations, and requires that instance to fail for every caught mutation.
Those diagnostics show the actual wrong amount/state. All twelve mutants pass
ordinary pure-program typechecking, and no mutant binary is emitted. The status-label
mutant still passes state-only laws, but fails the HTTP replay law and witness.
Three additional mutations fail authorization, GET-state and declared-status laws.

## Pure HTTP laws

[HTTP_PROOF.bend](HTTP_PROOF.bend) adds seven checked laws:

| Law | Exact guarantee |
| --- | --- |
| `replay_response` | For any state, supplied original Operation and retry inputs, a duplicate dispatch produces exactly unchanged state plus HTTP 200 and Replayed{original} |
| `transfer_status_declared` | For every engine Outcome and Operation, the pure transfer response's status occurs in the actual transfer route declaration |
| `protected_accounts_denied` | GET /protected/accounts without valid credentials returns exactly 401/unauthorized and no Execute plan |
| `unknown_route` | GET /absent returns exactly 404/not_found |
| `wrong_method_allow` | DELETE /transfers returns exactly 405/method_not_allowed with precisely ["POST"] |
| `get_does_not_write` | For every engine state, GET /accounts preserves complete modeled state even when the pure handler proposes zero balances |
| `head_does_not_write` | For every engine state, an explicitly declared HEAD /accounts likewise preserves state |

The eight [framework laws](../../src/CONTRACTS_PROOF.bend) also quantify over
arbitrary state/body types and handlers, including protected-route denial and
read-state preservation. Both proof files are imported by the ledger proof gate
and were checked by the independent kernel. There remain 28 engine/arithmetic
laws; these additions do not weaken or replace them.

The framework gate now also includes 34 [routing laws and
lemmas](../../src/ROUTING_PROOF.bend). They establish pure path matching, exact
captures, first method/path selection and Allow collection for arbitrary tables,
against an independent segment and two-observation specification. Their 404,
405 and protected-route 401 consequences quantify over arbitrary state/body
types and handlers. See the [exact scope and routing mutation
demo](../../docs/contracts.md#routing-and-the-edge); effectful routing and the
HTTP adapter remain tested edges.

The effectful adapter consumes the actual H.transfer/H.complete plans. Replay
conversion selects the persisted original operation before constructing the
final plan; the response adds its canonical fields as `operation`. The replay
theorem covers every supplied original operation. It does not establish that
the adapter fetched the correct receipt. SQLite write results are observations
at the edge; response encoding and committing the plan are tested, not proved.

The framework's read policy returns the input state regardless of a handler's
proposed change; no IO exists in that handler. The ledger's effectful read paths
still need review/tests to ensure they perform no SQLite writes. The pure access
plan runs before ledger dispatch. Its fixed public demo credential is not a
real authentication system; existing endpoints remain public.

## HTTP and SQLite edge (tested, not proved)

- `GET /health`: liveness. `GET /accounts`: current snapshot/version.
- `POST /transfers`: strict schema with `idempotency_key`, `expected_version`,
  `from`, `to`, `amount`. Source/target must be distinct alice/bob. Amount is an
  integer 1–200. Key is an integer 1–1,000,000; expected version is 1–4,294,967,294.
- Fresh database: 100 cents each, version 1. Startup writes a fixed initialization
  snapshot with a fixed SQLite operation ID; restart replays that initialization
  receipt instead of resetting the ledger. It makes no deposits or external calls.
- Reads validate stored JSON and its 200-cent supply before invoking the engine.
  Keys are derived from the retained successful request receipts. The adapter
  compares receipt fields to reject reuse of a successful key with different
  input. Validated requests are reconstructed in fixed field order before
  persistence, so even concurrent retries with different JSON field order
  produce identical SQLite inputs; parser duplicate keys remain last-wins.
- A transfer writes both balances and retained request receipts as **one** store
  value under key `ledger`. The version comparison and SQLite operation receipt
  commit together. A stale comparison returns 409 and gets a durable rejected
  SQLite receipt. A key naming that comparison cannot safely be repurposed.
- A successful retry returns current balances/version and `replayed:true`;
  `GET /operations/:id` returns the original SQLite applied version. Lost or
  uncertain acknowledgements must be reconciled using that route before retrying
  the same exact request. Never change its key merely to retry. A 404 receipt
  may race an in-flight write and does not prove it cannot still commit.
- Insufficient funds: 422, no snapshot/receipt write. Full successful-receipt list:
  409 `ledger_full`, no write. Existing successful keys can still replay at capacity.
  Database errors: 503 with a fixed store code. No implicit retry loop exists.
- GET /protected/accounts: synthetic gate, `X-Demo-Access: allowed`; missing or
  wrong value is 401 before reading storage. No credentials/login system.
- Loopback binding, no real authentication, TLS, arbitrary account creation, fees,
  money issuance, receipt compaction, bank integration or payment provider.

The persisted request-to-engine mapping, JSON encoding/decoding, HTTP URI parsing
and effectful routing, receipt field comparison, schema enforcement, whole-snapshot write discipline and
startup/restart logic are application code outside these proofs. SQLite atomicity
and durability depend on the C effect, SQLite, OS, filesystem and hardware.
Networking depends on Stiff's C ABI, libevent and json-c; libcurl is linked by the
standard build but the service makes no outbound request. All are trusted.

The proof establishes facts in Bend's model. BendTT independently checked the
exported equations; Bend's translation into BendTT, Base primitive semantics,
code generation, runtime and native ABI are still trusted. Nat's native
representation has a finite implementation limit, unlike its inductive model;
this HTTP example keeps all balances and their total at ≤ 200. Nothing here
claims complete memory safety or a production-ready financial system.

## Reproduce verification

```sh
make -C examples/ledger check mistakes test
make -C examples/ledger kernel verdict  # optional macOS arm64-only scoped bootstrap
make -C examples/ledger test-sanitize   # native compiler ABI with Stiff's ASan fix
```

`make kernel` downloads the official Lean 4.34.0 darwin_aarch64 archive, checks
SHA-256 `69f263fa6e21bbc2466bbfb1affcd92479ee2714c883a07de548e099a5922932`,
extracts it under `.cache/ledger/lean`, and explicitly compiles the pinned
`bendtt.lean` into `.cache/ledger/kernel/bendtt`. `make verdict` sets `BENDTT` to
that path, avoiding Bend's automatic global `~/.bend` cache. Override `BENDTT`
with another locally built kernel if needed. Neither target installs global tools.

To reuse an existing Stiff checkout's compiler and libevent instead of running
setup, set `BEND` to its `.cache/toolchain/bin/bend` and symlink its
`.cache/libevent` and `.cache/toolchain` into this checkout's `.cache`. Set
`STIFF_HEAVY_LOCK` to a directory path to make heavy build, server-test,
sanitizer and kernel-build tasks wait for one another across checkouts; by
default no lock is used. Bend engine checks and mutations are light.

The sanitizer result covers the generated Bend/Stiff C with the existing checked
ASan calling-convention mitigation, not uninstrumented SQLite/libevent/libcurl,
the unmodified default ABI, or a formal memory-safety claim.

[HTTP contract verification evidence](evidence/contracts-verification.json) records
the accepted kernel verdict, native ledger checks and the local RSS inspection
limitation. [CI run 37298832406](https://github.com/fraylabs/stiff/actions/runs/37298832406)
passed all four normal jobs on the implementation commit. Overall CI was 7/8:
the macOS Intel sanitized job failed an unrelated load-tool timing assertion
(0.7037 seconds against a 0.7-second bound); no bound was relaxed here.
