# Framework completion checklist

Stiff 0.2.0 release criteria, September 21, 2026. This is the
current result/evidence record, not a claim that passing unit tests establishes
production readiness. Unchecked requirements remain open.

- [ ] Richer application APIs: path parameters; boolean/numeric/optional/nested
  schema validation; consistent application and transport errors.
- [ ] Streaming and persistent connections: bounded response and request streaming,
  keep-alive, demonstrated SSE; evaluate WebSockets against an actual use case.
- [ ] Execution controls: cancellable running effects; hard process memory/CPU
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

Integration in progress. The pre-upload integration passed 112 normal tests.
Storage passed seven dedicated normal and compiler-profile sanitizer journeys,
including rejected-database preservation, lost acknowledgements and crash recovery.
The compiler mitigation passed all six diagnostic combinations and deliberate
ASan/UBSan fault canaries; raw upstream preserve_none remains an upstream issue.

Request streaming is moving to an isolated pinned libevent 2.2 alpha dependency
because the stable 2.1 server API has no pre-body request hook. Final integrated
normal/sanitizer runs, platform CI, workload repetitions and clean release artifacts
must cover that dependency before the remaining items are closed.
