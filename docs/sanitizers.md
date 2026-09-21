# Sanitizer investigation and diagnostic profile

Inspected compiler: Bend 2.0.20, source revision
`a5269a6b2c5ccd6752b66df4bc6f60678b4f49bc`. The original failure reproduces on
macOS arm64 with Apple Clang 21.0.0 (`clang-2100.1.1.101`).

## Finding

The Base-only `native-runtime-smoke.bend` prints one line and imports no Stiff
code. With the generated compiler calling conventions, combined ASan/UBSan
reports a null-pointer offset in `root_done`, then the original recovering build
hits Bend's generic memory-fault handler. The new fail-fast flags stop at the
first UBSan report instead.

Additional isolation builds retaining only `preserve_most` passed; retaining only
`preserve_none` reproduced the failure. LLVM tracks the underlying arm64 defect as
[ASan not respecting `preserve_none`](https://github.com/llvm/llvm-project/issues/177519),
and Clang describes the
[preserve_none ABI as unstable](https://clang.llvm.org/docs/AttributeReference.html#preserve-none).
LLVM also disabled `preserve_none` under ASan in its own interpreter implementation
in [PR 190001](https://github.com/llvm/llvm-project/pull/190001) rather than
suppressing ASan checks.

The supported Stiff resolution follows that boundary narrowly. Address or
combined instrumentation in the default `compiler` profile removes the two exact
generated `PRESERVE(preserve_none)` sites while retaining `preserve_most`.
UBSan-only and uninstrumented builds retain both Bend conventions. An unexpected
site count fails the build, so a changed compiler layout cannot silently broaden
the rewrite. This locates the observed incompatibility to compiler instrumentation;
it does not prove that normal uninstrumented binaries are broken.

The official Bend 2.0.24 macOS arm64 release (source revision
`2a7f7125cf218b6ff089c366fa8ce69e100d4a17`, archive SHA-256
`b17380ac7b8fce5c5c0250d23c9bb6d99cc9737bfca8a9e5428e051325926e1e`)
was tested separately and reproduces the same combined-sanitizer failure. Its
generated convention definitions are unchanged, so Stiff remains pinned to
2.0.20 rather than taking an unrelated compiler upgrade.

Observed Base-only matrix, `-O1 -g -fno-omit-frame-pointer`:

| Build profile | ASan | UBSan | ASan + UBSan |
| --- | --- | --- | --- |
| Unmitigated Bend output | Pass | Pass | Fail |
| Compiler profile with targeted resolution | Pass | Pass | Pass |
| Standard C | Pass | Pass | Pass |

A full Stiff run with ASan alone and the default calling conventions still
failed on larger client/JSON/server programs. Splitting the sanitizers therefore
is not a sufficient workaround. A successful Base smoke is not a suite result.

## Reproduce and test

```sh
make setup
make diagnose-sanitizers
make test-sanitize
```

The probe compiles/runs all six Base-only compiler/standard variants and writes
their actual exit codes, stdout, stderr, effective convention layout and
compiler/platform identity to `.cache/sanitizer-probe/report.json`. It requires
every variant to pass and verifies that the compiler profile removes only
`preserve_none` for address and combined instrumentation. The pre-resolution raw
failure is the finding above, not a supported build mode.

`make test-sanitize` selects:

```sh
STIFF_NATIVE_ABI=compiler STIFF_NATIVE_SANITIZE=combined make test
```

All generated Bend runtime and Stiff effect C is compiled with
`-fsanitize=address,undefined -fno-sanitize-recover=all`. Nothing is excluded with
`no_sanitize`, ignorelists, disabled leak detection or filtered diagnostics.
Two deliberate-fault fixtures require an ASan heap-overflow report and a UBSan
signed-overflow report with nonzero exits, proving both detectors are active.
The integration harness also checks unexpected sanitizer diagnostics and server
shutdown exit codes. The Git-pinned external example uses a dependency revision
that supports this profile.

Normal `make test` and application builds retain the compiler's original calling
conventions and optimization settings. Address-instrumented builds change only
the two generated `preserve_none` sites; `preserve_most` remains active. The
pinned compiler binary and upstream source remain unchanged. The `standard` ABI
option remains available for comparison and removes all generated preserve
attributes. No performance or binary-compatibility equivalence is claimed between
instrumented and normal builds.

`STIFF_NATIVE_SANITIZE` accepts `0`, `address`, `undefined`, `combined`, or `1`
(the compatibility alias for combined). `STIFF_NATIVE_ABI` accepts `compiler`
(default) or `standard`. These controls also work with `build-native.sh` directly.

CI targets normal and compiler-ABI combined-sanitizer profiles independently on
Linux/macOS arm64/x64. Completed-run evidence is recorded in checklist.md. The instrumented suite runs the
normal functional/proof checks plus the two deliberate-fault detector checks.

## Coverage limits

This resolves Stiff's default compiler-profile instrumentation failure without
disabling sanitizer checks. The underlying Clang `preserve_none` incompatibility
remains unresolved upstream. A future compiler claim must pass the raw
`preserve_none` reproducer and full Stiff suite before this targeted rewrite is
removed.

Passing checks are evidence for the exercised instrumented binaries, not a proof
of memory safety or verification of uninstrumented runtime behavior. Bend uses a
custom mmap arena: ASan does not automatically give each object inside that arena redzones
or lifetime poisoning. System libcurl, json-c and SQLite, and the pinned static libevent build, are not
rebuilt with instrumentation here. Leak/runtime ownership coverage is therefore
not exhaustive. Formal pure laws do not verify any of these native components.
Stiff remains experimental.
