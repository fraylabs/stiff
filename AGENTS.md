# Stiff

Stiff is an experimental native Bend 2 networking library. Keep changes inside
this repository and preserve the compiler pin until an upgrade is tested.
Never copy private product code, data or history.

- Read README.md for the current API and support boundary.
- Run `make setup`, then `make test` after changing code or laws. Setup and tests
  use Python's standard library; applications use the native Bend/C runtime.
- Keep src/PROOF.bend in the checks. Compiling an application alone does not
  verify its laws. Check the verdict, not just a successful exit status.
- Maintain the native-only workflow. Do not reintroduce JavaScript runtimes,
  package managers, hosted backends or test tooling.
- Server changes need the scoped pinned libevent build and native lifecycle/framing tests;
  preserve the distinction between network grace and application cancellation.
- Treat libcurl, libevent, json-c and the Bend compiler as trusted implementation, not
  formally verified code. Do not disable TLS verification or add implicit retries.
- Constructor packing is pinned private compiler ABI. Cover native layouts with
  actual compiled programs whenever types or foreign effects change.
- Keep compiler downloads, generated C, binaries and test certificates ignored.
- See docs/native.md for numeric/Unicode limits and docs/sanitizers.md for the
  generated-ABI instrumentation mitigation. Use `make test-sanitize` for
  the default compiler profile with its checked ASan calling-convention fix; never generalize its coverage to the default
  ABI, uninstrumented dependencies or full memory safety. No static portability claim.
