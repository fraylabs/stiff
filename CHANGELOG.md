# Changelog

## 0.4.0 — October 5, 2026

- Add pure HTTP contracts with compiler-checked protected-route, GET/HEAD state, and 404/405 laws in `src/contracts.bend`. Applications can prove declared statuses and response bodies.
- Add the proven two-account ledger example: conservation, overdraft rejection, unchanged rejection, idempotency, and HTTP response laws; twelve independently typechecked mistakes are rejected before building a binary.
- Run the consumer fresh-setup test in CI rather than on shared local machines.
- Harden load-test and shutdown timing checks against scheduler stalls while preserving arrival accounting and deadline checks.
- Add Linux x64 and arm64 release archives built and verified on hosted Ubuntu 24.04 runners, alongside macOS arm64.

Experimental release pinned to Bend 2.0.35. Proofs cover pure modeled decisions;
credential validation, decoding, persistence, serialization, native effects,
compiler/runtime and dependencies remain trusted/tested. See docs/contracts.md
and examples/ledger/PROOFS.md for the exact boundaries.

## 0.3.0 — October 4, 2026

- Support Bend 2.0.35 native effects, constructor packing and executable-name CLI arguments.
- Add daily latest-Bend CI with isolated candidate downloads and recorded integrity metadata.
- Check reachable native constructor arities at startup and reject corrupted HttpOk ABI descriptors.
- Make the quickstart server-first, with explicit native prerequisites and a local health check.
- Make load-test timing assertions tolerate runner stalls while retaining independent-arrival and accounting checks.

Experimental release; compiler/native dependencies remain trusted. See
docs/compatibility.md, docs/bend-2.0.35.md and docs/release-tracking.md for
verified coverage and limits. Published as an experimental release at
https://github.com/fraylabs/stiff/releases/tag/v0.3.0.

## 0.2.0 — September 21, 2026

- Add raw path parameters and nested typed request-schema validation.
- Add bounded request/response streams, SSE and explicit HTTP keep-alive for streams.
- Add native SQLite transactions with idempotent local results and recovery checks.
- Add the native `stiff-run` process cancellation/resource/logging boundary.
- Fix default-profile sanitizer builds for Clang's preserve_none incompatibility,
  retaining preserve_most and all sanitizer checks.
- Add independent-arrival load tooling, platform coverage and deployment/upgrade guidance.
- Add a persistent notes HTTP application combining schemas, versioned writes,
  idempotency, crash/restart reconciliation and request observability.
- Fix retained streaming callback lifetime and cover stale notifications, output
  drain, closure and connection/slot reuse with native regression checks.
- Package both native example applications, deployment units and dependency manifests.

Experimental API; see docs/compatibility.md and docs/checklist.md for verified
coverage and remaining limits. Published as an experimental release at
https://github.com/fraylabs/stiff/releases/tag/v0.2.0.
