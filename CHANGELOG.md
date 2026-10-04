# Changelog

## 0.3.0 — October 4, 2026

- Support Bend 2.0.35 native effects, constructor packing and executable-name CLI arguments.
- Add daily latest-Bend CI with isolated candidate downloads and recorded integrity metadata.
- Check reachable native constructor arities at startup and reject corrupted HttpOk ABI descriptors.
- Make the quickstart server-first, with explicit native prerequisites and a local health check.
- Make load-test timing assertions tolerate runner stalls while retaining independent-arrival and accounting checks.

Experimental release; compiler/native dependencies remain trusted. See
docs/compatibility.md, docs/bend-2.0.35.md and docs/release-tracking.md for
verified coverage and limits.

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
