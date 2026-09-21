# Framework completion checklist

Stiff 0.2.0 release criteria, September 21, 2026. This is the
current result/evidence record, not a claim that passing unit tests establishes
production readiness. Unchecked requirements remain open.

September 21 callback lifetime repair: the retained libevent chunk callback now
uses stable slot storage instead of the freed effect reply, checks connection
ownership, and waits for the HTTP-facing output buffer to drain. The deterministic
regression in `test/fixtures/stream-callback-lifetime.c` covers repeated callbacks
after reply reclamation, pending output, closed/cleared slots and slot reuse on a
different connection. An isolated build of the original callback fails this
regression with ASan `heap-use-after-free`; the repaired callback passes.
Stiff Builder 2 verified **132 normal tests** and **135 compiler-profile combined
ASan/UBSan tests** on local macOS arm64, including pure proof verdicts, native
server/streaming journeys and sanitizer detector checks. Local logs are retained
under ignored `.cache/stiff-builder-2-{normal-tests,sanitizer-tests,before-fix}.log`.
This fixes the observed lifetime defect; platform CI and release completion
remain open below. Existing sanitizer coverage limits still apply.

- [x] Richer application APIs: path parameters; boolean/numeric/optional/nested
  schema validation; consistent application and transport errors.
- [x] Streaming and persistent connections: bounded response and request streaming,
  keep-alive, demonstrated SSE; evaluate WebSockets against an actual use case.
- [x] Execution controls: cancellable running effects; hard process memory/CPU
  limits; bounded logging resilient to slow/failed sinks.
- [x] Persistence and recovery: atomic transactions, restart/crash recovery,
  idempotency conflicts and uncertain-operation handling.
- [ ] Verification: independently driven load, repeated longer soaks, varied
  workloads, native and sanitizer journeys across supported platforms.
- [x] Compiler/runtime: resolve the default calling-convention instrumentation
  failure without suppressing checks or merely renaming the diagnostic profile.
- [ ] Release stability: documented/versioned API contract, upgrade guidance,
  deployment examples, and verified release artifacts.

Existing delivered baseline: native HTTP(S)/JSON client, bounded HTTP server,
cooperative checkpoints and handler budgets, exact routes/middleware/text
validation, correlation/logging/metrics. Baseline commit `6e1a3b0` passed 81 normal
and 83 diagnostic-sanitizer tests on macOS arm64 and Linux CI. New work below must
supply its own evidence; those results do not cover the pending changes.

Before the callback lifetime repair, the local compiler-profile ASan/UBSan suite
passed **134 tests**. Dedicated
transport checks passed 18 streaming and 27 existing server tests in both normal
and combined-sanitizer builds. Independent QA additionally exercised blocked
response writes through reset, deadline and shutdown grace. Storage covers
rejected-database preservation, conflicting/replayed operations, lost
acknowledgements and crash recovery. The supervisor covers running HTTP effect
cancellation, CPU limits, platform memory behavior, descendant cleanup and
slow/failed logging, including injected setup failure and interrupted syscalls.

The compiler mitigation passed all six diagnostic combinations and deliberate
ASan/UBSan fault canaries. Normal output retains Bend's calling conventions;
instrumented output changes only the two ASan-incompatible `preserve_none` sites.
This is not a proof of generated-runtime or dependency memory safety.

Release contracts are documented in [compatibility](compatibility.md),
[streaming](streaming.md), [storage](store.md), [execution](execution.md),
[schema](schema.md) and [dependency pins](dependencies.md). Request streaming
uses pinned libevent 2.2.2-alpha with a tracked, hash-verified error-header patch.
Content-Length uploads use a 64 KiB Bend-facing queue; chunk-framed uploads can
buffer one complete frame up to the configured aggregate body limit. Per-handler
cancellation remains cooperative; preemptive cancellation uses an isolated
process. Linux cgroups provide the deployment resident-memory boundary.
WebSockets and HTTP/2 are outside this release; SSE covers the demonstrated
streaming use case.

Final platform CI, repeated load reports and clean release packaging are still
in progress. The remaining boxes stay open until their actual results are linked.

Two sequential 300-second runs against one native process offered 100 requests/s
from an independent process scheduler: **30,000 GET + 30,000 POST succeeded**,
with zero client drops, transport/status/semantic errors or timeouts. The process
then passed a fresh health request and graceful shutdown. Exact reports:
[health](evidence/2026-09-21-health-300s.json) and
[greeting](evidence/2026-09-21-greeting-300s.json). P99 completion latency was
9.50 ms and 9.97 ms respectively on a shared macOS arm64 development host;
these loopback observations are not deployment capacity or long-duration
production evidence. The reports retain dirty-tree provenance and an independently
verified matching committed source tree (`fd00415`). Subsequent source changes
are a comment and an explicit compile-time bracket-depth allowance.
