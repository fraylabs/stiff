# Bend 2.0.36 upgrade

This report records the initial compiler upgrade from Bend 2.0.35 to 2.0.36,
source `ae1101ca7d15364f9274fa6b1367d175884a7da7`, on branch `bend-2.0.36`
from Stiff 0.6.0 revision `9b7cebc`. The initial light-validation scope is preserved below. Full native and sanitizer
CI subsequently passed on `0a3a746faed7fcd9138a868997834c2e328e6af1`: [Check](https://github.com/fraylabs/stiff/actions/runs/37813873059)
(8/8) and [Latest Bend compatibility](https://github.com/fraylabs/stiff/actions/runs/37813873702)
(all green after rerunning one runner-interrupted job). Stiff 0.6.1 moves the
starter and consumers to the new compiler; [release evidence](evidence/0.6.1)
records the final source and publication checks.
Published 0.6.0 archives, Git consumer revisions and the immutable BendHub
package still require 2.0.35. The initial upgrade did not include a release operation.

## Release completion

Stiff 0.6.1 is published with Bend 2.0.36. Both the source-anchor and final-source
Check matrices passed 8/8. Hosted publication and Linux x64/arm64 consumer
verification passed; all six GitHub assets matched retained build bytes.
The starter and both consumers now pin 0.6.1. The remaining sections preserve the
initial upgrade analysis and light-validation scope, including the consumer state
at that time; final receipts are in [0.6.1 release evidence](evidence/0.6.1).
Independent kernel verdicts were not run.

## What changed upstream and why it broke

Upstream [PR #1281](https://github.com/bendlang/bend/pull/1281), commit
`bf96827121`, removed the registration-time wait policy. In 2.0.35,
`io_eff(u32 cid, Effect run, u32 need)` stored `{run, ask}` in an `IoEff` row:
`need = 0` dispatched immediately, `IO_READ` waited for the handle in the
first argument to become readable, and `IO_TIME` waited for the first argument's
millisecond duration. This was a pre-dispatch polling policy, not a flag to
execute the effect on a worker thread.

In 2.0.36, registration is `io_eff(u32 cid, Effect run)` and the table contains
function pointers directly. `io_step` unpacks the request, saves its continuation
and calls the effect immediately. Effects now explicitly park themselves using
`io_wait_on` for readiness/deadlines or `io_work` for helper-thread work. This
explains the daily compatibility failure's C “too many arguments” diagnostics.

All **24 production registrations** and the sanitizer canary passed `0`.
They now use two arguments. No replacement wait is needed for that immediate
dispatch behavior. HTTP transfers and the blocking server next/body/reply/stop
paths already return `io_work(w, call, pack)`; those calls remain intact.
The upstream `io_work`, `io_help` and `io_wait_on` function bodies are unchanged
between the two tags. Helpers still touch scratch data only, with packing and
Bend heap access on the IO loop. Synchronous JSON, URL, SQLite and immediate
server effects retain their existing execution behavior. This is a source-level
behavior comparison plus a small HTTP smoke check, not full concurrency evidence.

Sources: [tag comparison](https://github.com/bendlang/bend/compare/v2.0.35...v2.0.36),
[old runtime](https://github.com/bendlang/bend/blob/v2.0.35/bend2/comp.ts),
[new runtime](https://github.com/bendlang/bend/blob/v2.0.36/bend2/comp.ts),
[updated effects guide](https://github.com/bendlang/bend/blob/v2.0.36/guide/EFFECTS.md),
[release](https://github.com/bendlang/bend/releases/tag/v2.0.36).

## Pin and compatibility changes

Setup, native version guards, package metadata, diagnostics, current example
gates and compiler documentation now name 2.0.36. The four archive pins match
both the release's published checksums and GitHub asset digests:

| Platform | Archive SHA-256 |
| --- | --- |
| darwin-arm64 | `2876687ceb0aba836abc98b3f62c8fc9fb612d124ae2af6814d5ec937760878d` |
| darwin-x64 | `925bb306c60260e1cdde56c2b8e4ba0e1eb4cbc88a76372cc0bb389a172dccdf` |
| linux-arm64 | `a14a311e39bad45f9669d4eab39d156b578c945f13a2b7bae20d9c23567a4664` |
| linux-x64 | `02089dc0eed0fd5fd6d73c74cc9cffcb2c6638dd3b02ae83f7b8cc57fbe381ba` |

The optional ledger BendTT bootstrap now checks the 2.0.36 kernel source hash
`c40d2b219c77c64de1fd6c32224cc53fa928436d8ab7df5bf5a7e585d556cc32`.
Lean remains pinned to 4.34.0. No kernel was built or executed for this report.

The standalone proven-API template still fetches the published 0.6.0 revision
and requires 2.0.35. When `STIFF_CACHE` points to a newer checkout, it shares
libevent but links the compiler only if its checksum matches the fetched
revision's compiler pins. Otherwise dependency setup installs its own compiler.
This keeps the existing CI starter journey valid without moving an immutable
consumer pin to unpublished code. Existing-cache setup continues to reject a
mismatched pin; save the old compiler cache before ordinary upgrade setup.

## Private compiler ABI inventory deltas

The [2.0.35 inventory](bend-2.0.35.md#private-compiler-abi-inventory) remains the
baseline for all five production effect files, build tooling and test fixtures.
These are the changes relevant to that boundary:

| Boundary | 2.0.36 delta and Stiff response |
| --- | --- |
| All five `*_register` functions and canary | `io_eff` loses `u32 need`; replace all immediate registrations with two arguments. `Effect` remains `Term (*)(Env, Term*, IoWork*)`. CID substitution, reachability guards and constructor hooks remain in use. |
| Request unpacking / argument ownership | The former `io_exec` unpack-and-dispatch step is folded into `io_step`. It still uses `ctr_take`, reclaims the request spare with `spare_free(cls_fit(n))`, stores `fs[n-1]` as continuation and passes arguments in order. Stiff does not retain the transient field array across helper callbacks. |
| `IoWork` | A `prev` link is added for the runtime's parked queue. Stiff uses named scratch fields, never allocates/copies this struct or pins its size; no adapter change is needed. The guide clarifies that `word` becomes the fd while parked by `io_wait_on`; Stiff's helper paths retain their state in `data`. |
| `ctr_take` / shared cells | Implementation now reads through `term_peek` and the atomic count with an acquire before reclaiming a singly owned cell, replacing `rfc_view`. Its signature and the consume/unpack/spare contract remain unchanged. Stiff continues to use the helper rather than accessing those counters. |
| String construction | `io_str` tracks the pending tail with a `Term*` instead of a heap index. Its signature, UTF-8 conversion and String representation stay the same; Stiff requires no change. |
| Constructor emission / marshaling | Upstream fixes branch-local spare reuse, declared field-type emission and boxed datatype registration. Stiff's declared arity checks and raw field order remain unchanged. The client smoke exercises HttpOk/Response and JSON; server, streaming, metrics, URL and store round trips still require CI. |
| Shared-value reference counts | Upstream now explicitly fail-stops above `2^24-1` live copies on the C runtime. Stiff does not manipulate those counts or add a workaround; pure laws do not establish unbounded native representation capacity. |
| Helper-thread boundary | `io_work`, `io_help` and `io_wait_on` are unchanged. No new worker-thread Env access, retries, deadlines or cancellation behavior is introduced. |
| Calling conventions | The smoke's generated C retains two `PRESERVE(preserve_none)` sites and the expected `PRESERVE` macro spelling. The existing checked sanitizer mitigation is unchanged; sanitizer execution is pending. |
| Build-time ABI detection | Before Clang, require the exact generated `io_eff` and `Effect` declarations. Unexpected signatures produce `Stiff ABI mismatch` with the expected contract. A negative test changes each declaration and verifies that Clang is never invoked. This detects signature/spelling drift, not semantic drift or field ownership errors. |

No stable/versioned upstream C effect ABI is claimed. Existing compiled
descriptor-corruption and native layout tests remain necessary alongside the
new signature gate.

## Light validation

On macOS arm64, with the checksum-verified scoped 2.0.36 compiler:

- Framework `src/PROOF.bend` and ledger/bookings application `check` gates:
  `ALL PROOFS CHECK`, with no failure verdict.
- `make -C examples/ledger check mistakes`: passed; **12/12** mutations caught
  by generic proofs and concrete witnesses; ordinary mutant code typechecks.
- `make -C examples/bookings check mistakes`: passed; **6/6** caught.
- `make routing-mistakes`: passed; **4/4** caught by universal and concrete laws.
- Deliberately false framework proof: rejected with `SOME PROOFS FAIL`.
- New ABI signature test: passed both altered-signature cases without compiling C.
- New template shared-cache test: passed matching and mismatched compiler cases,
  without downloads or native builds.
- One small native build, `examples/get-json.bend`: passed. Its loopback JSON
  response printed `HTTP 200` and the expected title, with exit 0 and clean stderr.
  A closed loopback port produced the expected network error and exit 1.

Only one native program was compiled. No local `make test`, sanitizers, native
example test targets, libevent rebuild or independent kernel work was performed.
Compiler downloads, generated C, binaries and raw logs remain in ignored cache.
[Validation metadata and log hashes](evidence/bend-2.0.36.json) record these checks.

## Initial verification requirements and upstream issues

Run the full pinned **Check** matrix (Linux x64/arm64 and macOS arm64/x64,
normal and combined sanitizers) plus **Latest Bend compatibility** (four test
jobs plus resolution) on the committed branch. This must cover compiled ABI
descriptor corruption, HTTP/HTTPS, JSON/URL/store layouts, server lifecycle,
framing, streaming/upload/callback lifetimes, cancellation, packaging and the
standalone consumer/template journeys. These hosted checks subsequently passed as linked above. Independent `--verdict` remains separate and was not run here.

No new upstream bug was found, so no workaround, repro or issue filing was
needed. The documented registration change accounts for the observed C error.
The existing Clang sanitizer issue and narrow mitigation remain as documented
in [sanitizers](sanitizers.md). A versioned effect ABI would reduce future
patch-release breaks, but is an API request rather than evidence of a new bug.
