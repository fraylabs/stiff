# Money moves. The total doesn't.

A native HTTP money API on **Stiff + Bend 2.0.35**. Two accounts start with 100
demo cents each. Its pure engine proves, for arbitrary natural-number balances,
amounts and key lists: transfers conserve the total, overdrafts reject, rejection
preserves the complete state, and the same key cannot apply a transfer twice.
HTTP handlers call that engine and do no balance arithmetic.

Our [Bend/Rust comparison](../kingdom-comparison/RESULTS.md) found a credit of 6
paired with a debit of 5 that Bend's proofs missed. There was no conservation law.
Here, that law covers the actual transfer entry point.

## Try it

From a Stiff checkout with its pinned compiler and native dependencies available:

```sh
make -C examples/ledger check       # require ALL PROOFS CHECK, not just exit 0
make -C examples/ledger mistakes    # nine independent patches; no binary built
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

`mistakes` applies each [small patch](mistakes/) to four source files copied into
`.cache/ledger`. Shipped sources stay untouched. Every mutant passes ordinary
engine typechecking; eight fail the accounting proof gate and a concrete instance
of the rule below. The ninth demonstrates a coverage gap.

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
| Label a replay “applied” | No response-label law | **Missed** |

The CLI names the exact failing law instance and first failing generic proof.
[Diagnostics](evidence/mutations.json) show expected/observed terms. `make build`
requires the verdict before compiling. Building `main.bend` directly bypasses it.

## Where the proof stops

[All 28 laws and precise limits](PROOFS.md) are documented. Nonnegativity follows
from natural-number balances; separate overdraft and exact debit/credit laws stop
clamped subtraction from minting money. Idempotency means equal **engine state**,
including keys, not identical responses. Replays return current balances/version.
Rejection reserves no key; a later changed state may accept that rejected request.

SQLite commits both balances and receipts as one versioned snapshot. That
integration is tested, **not proven**. Routing, schemas, JSON conversion, request
identity, SQLite, C effects, libevent, json-c, libcurl, the compiler/runtime and OS
remain trusted. The proofs cannot establish that the adapter supplied the intended
amount. This is a two-account, 200-cent demo with at most 1,000 successful keys,
without authentication or external payments.

Independent `--verdict` **succeeded** with `ALL PROOFS CHECK`. Optional
`make kernel verdict` builds a scoped BendTT kernel using checksum-pinned
[Lean 4.34.0](https://github.com/leanprover/lean4/releases/tag/v4.34.0) on macOS
arm64, under `.cache/ledger`; no global install. Other platforms can set `BENDTT`.
The translation into BendTT remains trusted. [Evidence](evidence/verification.json)
records source hashes and inspected exported equations.

`make test` checks races, restart, lost acknowledgement/SIGKILL, independently
calculated histories and receipt capacity against the native executable with no
tools on PATH. `make test-sanitize` uses Stiff's documented diagnostic ABI profile.
Python is tooling only. MIT; no JS runtime, npm or hosted service.
