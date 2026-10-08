# Money moves. The total doesn't.

A native HTTP money API on **Stiff + Bend 2.0.36**. Two accounts start with 100
demo cents each. Its pure engine proves, for arbitrary natural-number balances,
amounts and key lists: transfers conserve the total, overdrafts reject, rejection
preserves the complete state, and the same key cannot apply a transfer twice.
HTTP handlers call that engine and do no balance arithmetic.
[Pure HTTP contracts](../../docs/contracts.md) now prove the replay response tag
and original operation, authorization policy and modeled read-state preservation.

Our [Bend/Rust comparison](../kingdom-comparison/RESULTS.md) found a credit of 6
paired with a debit of 5 that Bend's proofs missed. There was no conservation law.
Here, that law covers the actual transfer entry point.

## Try it

From a Stiff checkout with its pinned compiler and native dependencies available:

```sh
make -C examples/ledger check       # require ALL PROOFS CHECK, not just exit 0
make -C examples/ledger mistakes    # twelve independent patches; no binary built
make -C examples/ledger run         # native server, loopback :8080, persistent DB
```

In another terminal:

```sh
curl -s http://127.0.0.1:8080/accounts
# {"version":1,"replayed":false,"accounts":{"alice":100,"bob":100}}
curl -s http://127.0.0.1:8080/transfers -H 'Content-Type: application/json' \
  -d '{"idempotency_key":1,"expected_version":1,"from":"alice","to":"bob","amount":30}'
# {"version":2,"replayed":false,"accounts":{"alice":70,"bob":130}}
```

Send that request again: `replayed:true`, no second debit. Restart with the same
database: the key remains remembered. Lost response? `GET /operations/1` returns
the original SQLite committed version; `/accounts` returns the current snapshot.

## Ask the AI to make a mistake

`mistakes` applies each [small patch](mistakes/) to pure source files copied into
`.cache/ledger`. Shipped sources stay untouched. Every mutant passes ordinary
typechecking; all twelve fail the proof gate and a concrete instance of the
rule below. No mutant binary is built.

| Patch | Rule violated | Result before a binary exists |
| --- | --- | --- |
| Credit one extra cent | `transfer_conserves` | Caught |
| Credit without debiting | `transfer_conserves` | Caught |
| Remove insufficient-funds check | `transfer_conserves` on overdraft | Caught |
| Debit an unbalanced fee | `transfer_conserves` | Caught |
| Debit on rejection | `rejected_transfer_unchanged` | Caught |
| Apply again on retry | `same_key_twice_equals_once` | Caught |
| Forget the key | `same_key_twice_equals_once` | Caught |
| Reverse the accounts | `alice_exact_debit_credit` | Caught |
| Label a replay “applied” | `replay_response` | Caught |
| Remove the protected-route guard | `protected_accounts_denied` | Caught |
| Preserve a GET handler's proposed write | `get_does_not_write` | Caught |
| Return undeclared 201 on transfer | `transfer_status_declared` | Caught |

The CLI names the exact failing law instance and first failing generic proof.
[Diagnostics](evidence/mutations.json) show expected/observed terms. `make build`
requires the verdict before compiling. Building `main.bend` directly bypasses it.

## Where the proof stops

[The engine and HTTP laws and precise limits](PROOFS.md) are documented. Nonnegativity follows
from natural-number balances; separate overdraft and exact debit/credit laws stop
clamped subtraction from minting money. Idempotency means equal **engine state**,
including keys, not identical response bytes. The HTTP replay law separately
requires the Replayed body constructor and supplied original operation. Native
replies retain `replayed:true` and now include `operation` with the original
canonical request; balances/version remain current.
Rejection reserves no key; a later changed state may accept that rejected request.

SQLite commits both balances and receipts as one versioned snapshot. That
integration is tested, **not proven**. Route selection and authorization now use
a pure plan before effectful dispatch. Universal framework laws cover selected
protected routes regardless of the pure handler, and GET/HEAD complete modeled
state preservation. Concrete laws cover this table's 404/405 and Allow list;
there is no universal proof of the path matcher. Pure transfer outcomes always
have a declared status; other adapter errors and transport/encoding fallbacks
are not covered by that law. Schemas, JSON/domain conversion, original-receipt
selection, credential validation, SQLite, C effects, libevent, json-c, libcurl,
the compiler/runtime and OS remain trusted. The proofs cannot establish that the adapter supplied the intended
amount. This is a two-account, 200-cent demo with at most 1,000 successful keys,
without a real authentication system or external payments. Existing endpoints
remain public. The new `GET /protected/accounts` demonstrates the policy with
`X-Demo-Access: allowed`; this fixed public value is not a secret or login system.

Independent `--verdict` **succeeded** with `ALL PROOFS CHECK`. Optional
`make kernel verdict` builds a scoped BendTT kernel using checksum-pinned
[Lean 4.34.0](https://github.com/leanprover/lean4/releases/tag/v4.34.0) on macOS
arm64, under `.cache/ledger`; no global install. Other platforms can set `BENDTT`.
The translation into BendTT remains trusted. [HTTP contract evidence](evidence/contracts-verification.json)
records source hashes and inspected exported equations.

`make test` checks races, restart, lost acknowledgement/SIGKILL, independently
calculated histories and receipt capacity against the native executable with no
tools on PATH. `make test-sanitize` uses Stiff's documented diagnostic ABI profile.
Python is tooling only. MIT; no JS runtime, npm or hosted service.
