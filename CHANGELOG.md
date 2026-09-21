# Changelog

## 0.2.0 — unreleased candidate

- Add raw path parameters and nested typed request-schema validation.
- Add bounded request/response streams, SSE and explicit HTTP keep-alive for streams.
- Add native SQLite transactions with idempotent local results and recovery checks.
- Add the native `stiff-run` process cancellation/resource/logging boundary.
- Fix default-profile sanitizer builds for Clang's preserve_none incompatibility,
  retaining preserve_most and all sanitizer checks.
- Add independent-arrival load tooling, platform coverage and deployment/upgrade guidance.

Experimental API; see docs/compatibility.md and docs/checklist.md for verified
coverage and remaining limits. This entry does not imply a published release.
