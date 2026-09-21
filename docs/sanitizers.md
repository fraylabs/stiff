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

Changing only the generated `PRESERVE` macro to use ordinary C calling
conventions makes that same program pass with both checks enabled. Additional
isolation builds retaining only `preserve_most` passed; retaining only
`preserve_none` reproduced the failure. This locates the observed incompatibility
to instrumentation interacting with the generated calling convention; it does
not establish the exact faulty compiler transformation or prove that normal
uninstrumented binaries are broken. Clang itself describes the
[preserve_none ABI as unstable](https://clang.llvm.org/docs/AttributeReference.html#preserve-none).

Observed Base-only matrix, `-O1 -g -fno-omit-frame-pointer`:

| Generated calling conventions | ASan | UBSan | ASan + UBSan |
| --- | --- | --- | --- |
| Compiler default | Pass | Pass | Fail |
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

The probe compiles/runs all six Base-only variants and writes their actual exit
codes, stdout, stderr and compiler/platform identity to
`.cache/sanitizer-probe/report.json`. Raw-profile failures remain visible in the
report. The command requires the three standard-C variants to pass cleanly;
it does not assert that the default variants pass or must always fail on other
toolchains.

`make test-sanitize` selects:

```sh
STIFF_NATIVE_ABI=standard STIFF_NATIVE_SANITIZE=combined make test
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
conventions and optimization settings. The diagnostic profile is an explicit
alternative, not a silently patched production runtime. Only the generated C's
single exact `PRESERVE` definition is rewritten; an unexpected definition fails
closed. The pinned compiler binary and upstream source remain unchanged. No
performance or binary-compatibility equivalence is claimed between profiles.

`STIFF_NATIVE_SANITIZE` accepts `0`, `address`, `undefined`, `combined`, or `1`
(the compatibility alias for combined). `STIFF_NATIVE_ABI` accepts `compiler`
(default) or `standard`. These controls also work with `build-native.sh` directly.

CI runs normal and standard-ABI combined-sanitizer profiles independently on
Linux. Local evidence uses macOS arm64. The normal suite has 44 functional/proof
checks; the instrumented suite adds the two deliberate-fault detector checks.

## Coverage limits

This resolves the inability to exercise Stiff under combined sanitizers through
an explicit diagnostic build. The original instrumented calling-convention
incompatibility remains unresolved upstream. A supported compiler fix or upgrade
must be tested separately before removing this workaround.

Passing checks are evidence for the exercised diagnostic binaries, not a proof
of memory safety or verification of the default ABI. Bend uses a custom mmap
arena: ASan does not automatically give each object inside that arena redzones
or lifetime poisoning. System libcurl, json-c and libevent binaries are not
rebuilt with instrumentation here. Leak/runtime ownership coverage is therefore
not exhaustive. Formal pure laws do not verify any of these native components.
Stiff remains experimental.
