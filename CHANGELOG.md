# Changelog

## 0.2.0

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
coverage and remaining limits. This entry does not imply a published release.
