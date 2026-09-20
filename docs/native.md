# Native path proof

Stiff compiles a Bend `main() -> IO(...)` to C, links its HTTP and JSON effects
against libcurl and json-c, and runs as a native executable. The runnable application is `examples/get-json.bend`.

## Build

`make setup` installs the checksum-verified standalone Bend **2.0.20** release
under `.cache/toolchain`. Alternatively, supply an existing compiler with `BEND`.
The application build uses only Bend, Clang, pkg-config, libcurl and json-c:

```sh
./scripts/build-native.sh input.bend output
```

Python's standard library supplies the installer and test harness. There is no
JavaScript backend, package manifest or runtime, source loader, or npm tooling.
The build does not invoke Python once the compiler is installed.

Executables link dynamically. This is not a self-contained static binary: the
target machine still needs compatible libcurl/json-c libraries and a CA trust
store. Build on the target platform; there is no cross-compilation or Windows
support claim. Compiler/pkg-config flags currently assume dependency paths
without spaces. No global tools are installed by the setup or build scripts.

The native HTTP effect uses libcurl's easy interface on a Bend IO worker, with
an explicit [whole-transfer deadline](https://curl.se/libcurl/c/CURLOPT_TIMEOUT_MS.html).
It preserves TLS certificate/hostname verification, refuses non-HTTP protocols,
does not follow redirects, adds no retry loop, and limits decompressed response
bytes. UTF-8 is checked before constructing a Bend String.

JSON decoding uses [json-c's strict parser](https://json-c.github.io/json-c/json-c-current-release/doc/html/json__tokener_8h.html).
HTTP and JSON are separate effects; `Stiff.send_json` composes them in Bend.
No native effect calls Node or shells out to the curl command.

## Native-specific limits

- `STIFF_CA_BUNDLE` selects a PEM CA file without disabling verification.
- SIGINT terminates the native process through the OS. This stops continuation
  delivery, but is not a per-request cancellation API and cannot undo a remote
  side effect.
- The native backend inherits libcurl's supported compression, DNS, proxy and
  trust-store behavior.
- JSON entry order and numeric spelling may differ across parser versions. Native integer
  tokens outside ±9,007,199,254,740,991 fail with `json_number_range`, avoiding
  silent json-c integer saturation. No exact-number API is promised.
- Native JSON rejects NUL object keys and unpaired surrogate escapes rather
  than accepting json-c's lossy conversion. Embedded NUL string values and valid
  Unicode surrogate pairs are supported. JSON values deeper than 128 levels are
  rejected; native POST validation also imposes the parser's nesting bound.
- Constructor layouts are private Bend 2.0.20 ABI. In particular, HttpOk's nested
  Response is flattened and JsonBool packs its scalar in the constructor word.
  Request now carries six fields; its header list contains boxed two-field Header
  values. Real native tests cover these layouts; every compiler upgrade needs a
  rebuild and re-verification. Neither the compiler nor foreign effects are formally
  verified by Stiff's pure laws.

## Evidence and checks

Local development verification on macOS arm64 used Apple Clang, system libcurl
8.7.1 and json-c 0.19. The executable fetched public HTTPS JSON successfully with
`PATH=/nonexistent`; `file` identified a Mach-O arm64 executable and `otool -L`
listed libSystem, libcurl and libjson-c, with no Node runtime. The standalone
compiler build path is also exercised locally.

```sh
make test               # Native programs, transport fixtures and pure-law checks
```

The native suite copies binaries to an isolated temporary directory and runs
them with a minimal environment and no executable search path. It covers HTTPS
trust/rejection, GET/POST, no redirects/retries, deadlines, decompressed body
limits, invalid UTF-8, empty bodies, malformed JSON, native JSON constructors,
numeric/nesting limits and SIGINT. CI runs this suite on Linux using shell steps without JavaScript actions.

## Sanitizers: failed upstream-runtime check

An additional combined AddressSanitizer/UndefinedBehaviorSanitizer run **does not
pass** on the inspected macOS toolchain. It reports pointer arithmetic in the
generated Bend runtime and then `bend: memory fault (machine stack overflow?)`.
The following minimal program imports Base only, with no Stiff code, and
reproduces a sanitizer failure before its print succeeds:

```sh
STIFF_NATIVE_SANITIZE=1 ./scripts/build-native.sh \
  test/fixtures/native-runtime-smoke.bend .cache/native/runtime-smoke
./.cache/native/runtime-smoke
```

Observed UBSan report in that minimal case: `applying zero offset to null pointer`.
The HTTP build additionally reported overflowing pointer subtraction. This
isolates a failure to the pinned compiler/runtime configuration; it does not
establish that Stiff's native code is memory-safe. Upstream source is preserved
unchanged, checks are not suppressed, and no sanitizer-clean claim is made.
Keep this backend experimental until the runtime/checking issue is understood.
