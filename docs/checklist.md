# Framework completion checklist

Stiff **0.2.0** completes this bounded framework release checklist. Source revision
`4b20f169249b601d807b2d6aaeddda07a59532a2` is the verified release target.
[Published experimental release](https://github.com/fraylabs/stiff/releases/tag/v0.2.0).
Stiff remains experimental: completing these checks is not a general
production-readiness or memory-safety certification.

- [x] **Richer application APIs:** raw path parameters, unsigned integer/boolean/
  optional/nullable/array/nested-object schemas, unknown-field rejection and shared
  application/transport error envelopes. [API and contracts](schema.md).
- [x] **Streaming and persistent connections:** bounded request/response streaming,
  explicit keep-alive and working SSE. WebSockets and HTTP/2 are outside this
  release; SSE covers the demonstrated need. [Streaming contract](streaming.md).
- [x] **Execution controls:** cancellation of running native effects through an
  isolated process, hard CPU limits, Linux cgroup resident-memory enforcement,
  and bounded best-effort logging with slow/failed-sink tests. Per-handler
  cancellation remains cooperative. [Execution boundaries](execution.md).
- [x] **Persistence and recovery:** SQLite atomic version comparisons plus durable
  operation receipts, idempotent replays/conflicts, concurrent writes, SIGKILL
  recovery and uncertain-response reconciliation. [Store contract](store.md).
- [x] **Verification:** independent-arrival load, repeated longer local workloads,
  varied server/application/recovery tests, independent journey QA and passing
  normal/sanitizer jobs on Linux/macOS arm64/x64. Evidence below.
- [x] **Compiler/runtime:** the supported compiler-profile sanitizer build resolves
  the observed instrumentation incompatibility with the narrow `preserve_none`
  mitigation, retaining `preserve_most` and all checks. All six diagnostic
  combinations and deliberate detector canaries pass. The upstream Clang defect
  and native trust boundaries remain explicit. [Sanitizer contract](sanitizers.md).
- [x] **Release stability:** versioned API/upgrade contract, private store schema
  validation, deployment examples and a verified native archive with provenance,
  third-party notices and checksums. [Compatibility](compatibility.md),
  [deployment](../examples/deploy/notes.service), [changelog](../CHANGELOG.md).

## Integrated persistent application

The [notes HTTP application](notes.md) combines routing, nested schemas,
request observability and SQLite in one native executable. Its journeys cover
create/read/update, concurrent version races, replay/input conflicts, durable
rejected receipts, lost HTTP acknowledgements, SIGKILL/restart/reconciliation,
metrics, invalid input and packaged execution outside the checkout.

Independent QA on `bb12dc7` used a separate compiled executable and black-box
journeys, including 36 observed handler results, parallel identical requests,
request-ID spoof resistance, log redaction, oversized-body rejection and recovery.
Two QA findings were fixed and reverified: expected versions must leave room for
incrementing, and Unicode identifiers must fit the store's byte bound. The final
six-test application suite includes the corresponding boundary regressions.
There are no remaining blocking/high/medium findings from that review.

## Platform and lifetime verification

[All eight CI jobs](https://github.com/fraylabs/stiff/actions/runs/35609870142)
passed on release source `4b20f16`: Ubuntu 24.04 x64/arm64 and macOS 15 x64/arm64,
each with normal and combined ASan/UBSan builds. The normal suites run 138 tests;
the sanitizer suites run 141, including detector canaries. Both Linux normal jobs
also verify kernel cgroup resident-memory enforcement. Exact job results and
counts are in [platform evidence](evidence/0.2.0/platform.json).

The retained libevent callback now uses stable slot storage, checks connection
ownership and waits for output drain instead of retaining an effect-owned reply.
Its native regression covers reply reclamation, repeated/stale callbacks,
pending output, closure, cleared slots and connection/slot reuse. An isolated
original-callback build failed with ASan `heap-use-after-free`; the repair passes.
The Linux regression harness also selects Bend's feature macros before its first
system header. This does not change runtime code or suppress instrumentation.

All six local compiler/standard ABI diagnostic combinations passed:
[diagnostic evidence](evidence/0.2.0/sanitizer-profiles.json). Pure proof verdicts
and false-proof rejection remain in the full native suite. Normal binaries retain
Bend's original ABI; instrumented binaries make only the documented mitigation.

## Workload evidence

Two partially overlapping **600-second** local persistent runs each offered
30,000 reads and 15,000 idempotent PUTs from separate, independently scheduled
load processes: **90,000 requests total**, zero drops, timeouts, status, transport
or semantic failures. Each server then accepted a fresh mutation, shut down
cleanly, reopened the same database and returned the durable replay result.

- [First run](evidence/0.2.0/notes-soak-first-summary.json),
  [reads](evidence/0.2.0/notes-soak-first-reads.json),
  [writes/replays](evidence/0.2.0/notes-soak-first-replays.json).
- [Final application run](evidence/0.2.0/notes-soak-final-summary.json),
  [reads](evidence/0.2.0/notes-soak-final-reads.json),
  [writes/replays](evidence/0.2.0/notes-soak-final-replays.json).

The final run used clean `bb12dc7`; runtime source under `src/`, `native/`,
`scripts/`, `examples/` and `VERSION` is identical in release `4b20f16` (the only
later change is the Linux test harness). Final-run P99 was 14.25 ms for reads
and 14.81 ms for replays; sampled peak RSS was 22,288 KiB. The first run used
`5ac374f`, before the final identifier-bound correction. Reports retain exact
revision/binary provenance rather than attributing old results to new code.

These are finite, shared-host loopback measurements with repeated identical
writes, not deployment capacity, sustained fresh-write throughput, long-term
memory proof or separate-host network measurements. Earlier varied 300-second
GET/POST runs remain as [health](evidence/2026-09-21-health-300s.json) and
[greeting](evidence/2026-09-21-greeting-300s.json); their original revision limits
remain in those reports. Native tests separately exercise overload, streaming,
large/invalid bodies, concurrent fresh writes, cancellation and recovery.

## Release artifact and remaining boundaries

The clean macOS arm64 archive contains `app`, `notes`, `stiff-run`, deployment
units, licenses, dependency provenance and SHA-256 checksums. The exact archive
was extracted outside the checkout and passed supervised create/read/restart/
replay checks with no build tools on PATH. [Artifact verification and manifest](evidence/0.2.0/release-archive.json).
The published asset and checksum were downloaded again and matched the verified
local bytes. Other platforms build from the tested, pinned source.

The compiler stays at Bend 2.0.20; servers statically include scoped libevent
2.2.2-alpha. Native dependencies and compiler internals are trusted, not formally
verified. System curl/JSON/SQLite libraries remain dynamic dependencies.
macOS does not claim Linux's hard resident-memory contract. Notes is a local
single-workspace example, not authentication or a multi-tenant service. Store
receipts cover local transactions, not exactly-once external operations.
