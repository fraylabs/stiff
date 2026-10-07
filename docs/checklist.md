# Framework completion checklist

## Current release: 0.6.0

Stiff **0.6.0** targets Bend **2.0.35**. Pure route matching and selection
agree with an independent specification for arbitrary finite route tables,
methods, patterns and paths. This connects exact first-hit selection, captured
parameters and Allow methods to pure 404/405/401 dispatch laws.
`make routing-mistakes` catches four ordinarily typechecked mistakes with both
universal proofs and concrete false laws before building a mutant binary.
See [routing contracts](contracts.md#routing-and-the-edge) for semantics and
[release evidence](evidence/0.6.0/) for separate verification scopes.

Base split/equality semantics, compiler and Bend-to-BendTT translation, the
separate effectful Router, HTTP parsing, credentials, serialization, native
effects and persistence remain trusted/tested. These are pure modeled
dispatch laws; they do not prove every socket response or full memory safety.
Historical capacity measurements and independent kernel checks retain their
original revisions.

The starter and both consumers pin the immutable 0.6.0 source/build-tool anchor
`747a75915ad1b68bc60118e635915c9d3314a17e`. Release archives remain platform-specific
native examples requiring dynamic libcurl, json-c and SQLite, with patched
libevent 2.2.2-alpha included statically.

[Release-source CI](https://github.com/fraylabs/stiff/actions/runs/37608180748)
and [source-anchor CI](https://github.com/fraylabs/stiff/actions/runs/37607958163)
passed all eight platform/profile jobs each. All four normal release-source jobs
generated, set up, checked, built and mutation-checked the starter against its new
pin. [Anchor hashes](evidence/0.6.0/source-anchor.json) match the tagged library,
native sources and build tools.

The [hosted release workflow](https://github.com/fraylabs/stiff/actions/runs/37610062432)
published BendHub and built/verified both Linux archives. On Linux x64 and arm64,
empty-cache hub consumers matched all 23 source files, checked the framework
proof verdict, passed authenticated HTTPS and six persistent application journeys,
and rejected tampered cached native sources in the copied client.

All three exact clean archives passed provenance/checksums, supervised health,
create/read/restart and six persistent-notes journeys without build tools on PATH.
All six [published assets](https://github.com/fraylabs/stiff/releases/tag/v0.6.0)
were downloaded and byte-compared with their verified originals. Only light proof
checks and the single macOS archive build/verification ran locally; hosted CI
supplies the full-suite and sanitizer results. [Publication receipt](evidence/0.6.0/publication.json),
[archive results](evidence/0.6.0/release-archives.json) and [hub evidence](evidence/0.6.0/bendhub.json)
record exact revisions and separate scopes. Receipt commits follow the tag without
changing the released library or build tools.

## Historical 0.5.0 release

Stiff **0.5.0** targets Bend **2.0.35**. The [room-bookings example](../examples/bookings)
proves no double booking after an accepted booking on arbitrary schedules,
half-open slot semantics, exact cancellation and retry state equality.
Six ordinarily typechecked mistakes fail both the generic proof gate and a
concrete law instance before any mutant binary is built.

`make new NAME=myapi DIR=../myapi` generates a [standalone proven API](../templates/proven-api/README.md)
with an immutable Stiff source/build-tool pin. Its build checks framework and
application laws; changing its greeting is caught before compilation.
Heavy tasks honour the optional `STIFF_HEAVY_LOCK`; no lock is required by default.
Normal Linux/macOS CI jobs check both proven storage examples and generate,
set up, build and mutation-check a standalone starter.

The [BendHub package](bendhub.md) supplies the library sources and manifest.
The [experimental release](https://github.com/fraylabs/stiff/releases/tag/v0.5.0)
provides platform-specific macOS arm64 and Linux x64/arm64 archives of the app,
notes and supervisor examples. They dynamically require libcurl, json-c and
SQLite; patched libevent 2.2.2-alpha is statically included.

[Release evidence](evidence/0.5.0) records exact revisions and separate scopes.
The local suite passed 145 tests, skipped the CI-only fresh consumer setup and
failed only the RSS benchmark because the sandbox blocks `/bin/ps`.
Hosted CI supplies the full-suite result. Proofs cover pure modeled decisions;
credential validation, decoding, persisted receipt selection, serialization,
SQLite integration, native effects, compiler/runtime, dependencies and OS remain
trusted/tested. See [contracts](contracts.md) and [booking limits](../examples/bookings/PROOFS.md).
Historical measurements below retain their original revisions and are not new
0.5.0 capacity measurements.

[Final pinned CI](https://github.com/fraylabs/stiff/actions/runs/37508009362) passed
all eight platform/profile jobs on tagged source
`ef5cf4b9ec8c471f538e00e972cc89e5fdfbc453`. All four normal jobs generated,
set up, proof-checked, built and mutation-checked a starter against the new
`8767c10c84fdbadf92d3f7f9dc5b9c58be4b4157` pin. Its library/native build-tool
bytes match the tag; [anchor hashes](evidence/0.5.0/source-anchor.json) and
[starter results](evidence/0.5.0/starter.json) record that scope.

[Linux archive CI](https://github.com/fraylabs/stiff/actions/runs/37508030606)
passed both hosted builds. Each of the three clean archives passed exact
provenance/checksum, supervised health, create/read/restart and six persistent
notes journeys. All six published archives/checksum assets were downloaded
again and matched every original byte. [Platform results](evidence/0.5.0/platform.json),
[archive results](evidence/0.5.0/release-archives.json) and
[publication receipt](evidence/0.5.0/publication.json) record the exact scope.
BendHub was verified before tagging so the tag contains its immutable hash and
manifest; publication receipts follow without changing the tag.

## Historical 0.4.0 release

Stiff **0.4.0** targets Bend **2.0.35**. It adds [pure HTTP contracts](contracts.md)
with compiler-checked authorization, modeled GET/HEAD state preservation and
404/405 laws, plus the [proven ledger](../examples/ledger/README.md) with twelve
caught mistakes. Declared statuses and response bodies are application laws to
prove. Credential validation, decoding, original receipt selection, serialization,
SQLite, native effects, the compiler/runtime and dependencies remain trusted/tested.

The fresh consumer setup test runs in CI. Load and shutdown timing checks retain
arrival accounting and deadline checks while tolerating scheduler stalls.
The [BendHub package](bendhub.md) includes the contract modules, with immutable
consumer source/build-tool pins. The [experimental release](https://github.com/fraylabs/stiff/releases/tag/v0.4.0)
provides macOS arm64 and hosted Ubuntu 24.04 Linux x64/arm64 native archives;
these dynamically require libcurl, json-c and SQLite.

[Release verification evidence](evidence/0.4.0) records separate source revisions
and scopes. The local suite has one expected RSS failure because the sandbox
blocks `/bin/ps`, and skips fresh consumer setup; full-suite results come from
hosted CI. Ledger verification caught all twelve ordinarily typechecked mutations
and passed fifteen native journeys. The Linux archive workflow was rehearsed in
CI with exact-archive provenance, checksum, supervised health and persistent
journey checks before use for release builds. Historical measurements below
retain their original revisions and are not new 0.4.0 capacity measurements.

[Final pinned CI](https://github.com/fraylabs/stiff/actions/runs/37335463100) passed
all eight platform/profile jobs on tagged source
`945e73b4fd2a2b3b25e41fa696f3b908b7677e7e`.
[Final Linux archive CI](https://github.com/fraylabs/stiff/actions/runs/37335491116)
passed both hosted builds after the separate workflow rehearsal. Each of the three
clean archives passed provenance/checksum checks, supervised health,
create/read/restart and all six persistent notes journeys. All six published
assets were downloaded again and matched every original byte.
[Platform results](evidence/0.4.0/platform.json),
[archive results](evidence/0.4.0/release-archives.json) and
[publication receipt](evidence/0.4.0/publication.json) record the exact scope.
BendHub was verified before tagging so the tag contains its immutable hash and
manifest; publication receipts follow in a separate documentation commit.

## Historical 0.3.0 release

Stiff **0.3.0** supports Bend **2.0.35** and retains the bounded framework
contracts below. The release adds daily latest-Bend compatibility CI, startup
constructor ABI checks, a server-first quickstart and load-test timing robustness.
The [BendHub package](bendhub.md) and both standalone clients use 2.0.35.
[Experimental release](https://github.com/fraylabs/stiff/releases/tag/v0.3.0).

[Pinned Check](https://github.com/fraylabs/stiff/actions/runs/37202947714) passed
all eight Linux/macOS arm64/x64 normal/sanitizer jobs on release commit
`e55cf6cfcb60944b3170683fe8d4c90d046d889a`.
[Latest-Bend CI](https://github.com/fraylabs/stiff/actions/runs/37202947964) passed
four test jobs plus resolution on that same commit with Bend 2.0.35.
[Platform results](evidence/0.3.0/platform.json) retain the exact job scope.
The local native suite passed **147 tests in 148.086 seconds**, including the
copied Git-pinned HTTPS client; [local evidence](evidence/0.3.0/local-verification.json)
identifies the preparation tree and verified source hashes.

The clean macOS arm64 archive was built from the exact tagged commit. Its
checksums/provenance, supervised application health, persistent create/read/
restart and all six notes journeys passed with no build tools on PATH.
Both published assets were downloaded again and matched the verified local bytes.
[Archive evidence](evidence/0.3.0/release-archive.json),
[BendHub verification](evidence/0.3.0/bendhub.json) and
[publication order/receipt](evidence/0.3.0/publication.json) record these checks.
The compiler migration and latest-Bend checks have distinct scope; see
[the upgrade report](bend-2.0.35.md) and [release tracking](release-tracking.md).
Historical workload and independent QA results below remain attributed to their
original revisions; they are not new 0.3.0 measurements.

## Historical 0.2.0 completion

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

## Post-release compiler upgrade

The historical 0.2.0 evidence above retains its Bend 2.0.20 pin. The current
checkout targets 2.0.35; see [the upgrade report](bend-2.0.35.md) for local
verification. The old release archives and BendHub hash remain immutable. The 0.3.0 release
provides a separate 2.0.35 package and archive; see the current evidence above.
