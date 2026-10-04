# Bend 2.0.35 upgrade

This checkout targets Bend 2.0.35, source
`79df8d9c40722ee9507a1e253f283b51025f9d6c`, on branch `bend-2.0.35`
from `22ff9d3`. Release archives, historical evidence and the published BendHub
package still describe the older release; no publication is part of this upgrade.

## What changed

- Imported constructors/effect defs now emit module-scoped C identifiers. Old
  hard-coded `CID_HTTPERROR` names no longer compile. Old `#ifdef CID_STORE_OPEN`
  guards silently exclude registration, causing `bend: an alien request` at
  runtime. All five native effect files and the sanitizer canary now use the
  compiler's `CID(Name)` substitution, including conditional guards. Names resolve
  in the declaring Bend module, independently of import aliases and entry-file
  names. This also removes Stiff's dependence on C identifier spelling.
- The private `Loc` typedef was removed. Heap indices now use `u64`, as the current
  runtime and generated constructor code do. The three-field HttpOk/Response,
  six-field Received/Incoming, five-field StreamReceived/IncomingHead, ten-field
  Metrics, boxed Header and scalar JsonBool layouts remain the same in the
  exercised programs; no field reordering was needed.
- Since 2.0.32, `IO.args()` includes the executable name. Current checkout CLI
  examples and fixtures explicitly drop the head with `List.tail`. Invocation
  syntax remains unchanged for their users. The independent kingdom CLI also
  needed this adjustment; its historical comparison reports retain their dates.
- `--check-only` now prints `ALL PROOFS CHECK`. Test and verification scripts
  check that verdict, and the false-proof test must still fail. This is the
  compiler's checker, not an independent mathematical kernel verification:
  `--verdict` needs Lean v4.34.0 or a built BendTT kernel. That additional check
  was attempted but could not run because neither is installed on this Mac.
- Setup pins all four upstream archive SHA-256 values; native builds, package
  manifests and diagnostics require/report 2.0.35. The old scoped compiler was
  moved to `.cache/toolchain-2.0.20`, leaving global installations untouched.
- The two-site ASan `preserve_none` mitigation still matches this compiler.
  This Mac's Apple Clang 21.0.0 (`clang-2100.3.34.2`) additionally looks for a
  symbolizer at startup under an empty PATH. The test harness gives ASan/UBSan
  `/usr/bin/atos` explicitly. It suppresses no checks or diagnostics and retains
  `/nonexistent` as application PATH.
- The isolated Git-pinned consumer rebuilds libevent from source. Its setup/build
  test budget is now 600 seconds rather than 120 seconds, matching the dependency
  builder's own allowance. A combined-sanitizer run exceeded the old budget and
  raced temporary-directory cleanup while the build child was still writing.
  The consumer's published Git pin and Bend 2.0.20 dependency remain intact; this
  check is a historical integration check, distinct from current-checkout tests.

Upstream references: [2.0.35 release](https://github.com/bendlang/bend/releases/tag/v2.0.35),
[changelog](https://github.com/bendlang/bend/blob/v2.0.35/CHANGELOG.md),
[effect interface](https://github.com/bendlang/bend/blob/v2.0.35/guide/EFFECTS.md),
[compiler/runtime source](https://github.com/bendlang/bend/blob/v2.0.35/bend2/comp.ts).

## Private compiler ABI inventory

The complete production boundary is in `src/effects/{stiff,json,url,server,store}.c`
and `scripts/build-native.sh`. Bend public modules import those sources directly.
No other production C file (`native/stiff-run.c`) consumes Bend runtime objects.
`CID(Name)` and the basic effect helpers are documented upstream today; their
C runtime implementation still has no versioned stable ABI contract.

| Location / functions | Assumptions |
| --- | --- |
| All five effect files: `*_run`, `*_register` | Compiler splices foreign C after the runtime; `Term`, `Env`, `IoWork`, integer aliases and runtime helpers are visible. `Term* f` is in declared argument order, U32 is an unboxed word, registration uses `io_eff` and request constructor IDs, C constructor hooks run before main. `#ifdef CID(Name)` reflects reachable effects/constructors. |
| All five: value conversion and cleanup | `term_aux` is a constructor tag; `term_pak`, `term_ctr`, `io_box`, `io_node` implement scalar/nullary, boxed single-field and two-field construction. `ctr_take` consumes/unpacks the specified field count; its returned spare is reclaimed with matching `spare_free(cls_fit(n))`. `term_sink` consumes remaining values. Correctness depends on reference ownership, static/shared values and hot-constructor sealing as implemented by those helpers. |
| All five: strings/lists | String is SNil/SCon with unboxed Unicode scalar and tail; List is Nil/Con with element and tail, two fields. `io_str`, `io_cstr`, `io_utf8`, `io_mem`, `err_fail` are runtime routines with allocation/error/ownership contracts. JSON/URL/store additionally traverse String manually. |
| `stiff.c`: `stiff_send_run`, `stiff_send_pack` | Request fields are method, URL, body, timeout, limit, headers (6). Header/ResponseHeader are boxed name/value pairs, in a list. HttpError has code/message (2). HttpOk flattens Response into status/body/headers (3). Direct `heap_alloc(cls_fit(3))`, `e.mem` writes and `term_ctr` bypass a generic constructor helper. |
| `json.c`: `stiff_json_value`, `stiff_json_encode`, `json_parse_run`, `json_stringify_with_limit_run` | JsonNull is nullary; JsonBool flattens Bool into the packed constructor payload, read with `term_loc`. JsonNumber/String/Array/Object have one boxed field. Array is a list; object is a list of two-field Tuple (Sigma) key/value pairs. JsonDone, JsonEncoded use one-field boxes; JsonFailure/JsonEncodeFailure use two fields. Effect arguments are text, or value/limit. |
| `url.c`: `stiff_url_query_run`, `stiff_url_result`, `stiff_url_encode_run` | QueryParam is boxed name/value (2) inside list nodes. UrlReady/UrlError each box a String. Argument positions are text, or base/params. |
| `server.c`: `sg_listen`, listen variants | Config is address/port/max_body/max_pending/timeout/grace (6); TransportLimits is connections/read_timeout (2). Listening packs port in its constructor word; ListenError boxes a String. |
| `server.c`: `server_next_pack`, `server_next_stream_pack`, `server_metrics_run` | Received flattens Incoming into id/method/path/target/headers/body (6), StreamReceived flattens IncomingHead into the first 5 fields; ServerHeader is name/value (2). Metrics has 10 U32 fields in `SM_*` order matching `server.bend`. These three constructors use raw heap allocation and `e.mem` writes. Stopped/StreamStopped are nullary. |
| `server.c`: reply/stream/body/lifecycle effects | Reply is status/headers/body (3); header lists contain boxed ServerHeader pairs. BodyChunk/BodyFailure box a String, BodyEnd/Sent are nullary, ReplyError boxes a String, Bool/Unit are packed Base constructors. Raw streaming effects rely on positional id/status/headers/keep_alive, id/chunk, and id arguments. |
| `store.c`: `stiff_store_path`, open/read/write/operation effects | Store flattens to one String field consumed by `ctr_take(1)`, StoreReady uses `io_box`. StoreFound and version-conflict results have version/value (2). StoreApplied/StoreReplayed pack version directly; missing/idempotency/unknown results are nullary. Operation results have key/version (2) or key (1). Open/read/write/operation errors have code/message (2). All input arguments follow the corresponding Bend def order. |
| `stiff.c`, `server.c`: asynchronous work | `io_work` returns the runtime parking sentinel; `IoWork.data` and other used scratch members survive the helper-thread callback and are available to the pack callback on the IO loop. Helpers never access Env on worker threads. Runtime owns the work item; Stiff owns and releases its scratch buffers. |
| `scripts/build-native.sh` | `bend version` output and `-o ...c` behavior; effect-marker defines select libraries. Generated `PRESERVE` macro has one exact spelling and two `PRESERVE(preserve_none)` sites. Compiler/standard sanitizer profiles rewrite those checked strings. Clang accepts the conventions and finite bracket-depth flag. |

Verification-only dependencies: `test/fixtures/sanitizer-canary.c` uses the effect
ABI and Unit; `test/fixtures/stream-callback-lifetime.c` includes generated C,
renames main and accesses Stiff's internal server structs/functions;
`test/test_sanitizers.py` and `scripts/diagnose-sanitizers.py` assert generated
convention strings/counts. `scripts/verify-bendhub.py` compiles effects and checks
the proof verdict; it must be run at the source revision matching the immutable
package. Packaging records the exact pin rather than accepting arbitrary compilers.

## How to shrink or detect this boundary

1. Keep `CID(Name)` instead of generated names (done). Ask upstream for a
   versioned C effect API, constructor descriptors, take/build helpers for any
   arity, and ownership rules. Generate adapters from Bend types so flattening,
   field order and scalar packing come from the compiler.
2. Move result construction and input-record deconstruction into Bend wrappers.
   Foreign effects can accept primitive arguments and return small standard
   tuples; Bend constructs HttpOk, Received, Metrics and store variants. This
   reduces raw `e.mem` access and library-specific flattened layouts. JSON's
   recursive sum still needs an adapter or a byte-oriented interchange format.
3. Centralize remaining manual marshaling in a small checked adapter. At startup
   assert constructor arity/hot metadata for every raw allocation and unpack;
   these checks cannot by themselves prove field type/order or ownership.
   Keep compiled round trips with distinctive values for every field and variant.
   The new compiler regression fixture covers same-named entry constructors and
   executable-name/escaped runtime-flag argument behavior; existing real HTTP,
   JSON, server, streaming, metrics and store journeys cover the larger layouts.
4. Add a release compatibility workflow, separate from the pinned blocking
   matrix: on a weekly schedule or manual dispatch, enumerate new Bend releases,
   download their artifacts to an isolated cache, verify release digests, and
   patch only a disposable checkout's version guards/manifests to the candidate.
   Run normal, sanitizer and proof-negative suites across OS/architecture;
   attach logs, compiler source SHA, archive hash and generated C to the result.
   Do not auto-update the production pin or publish. A simple BEND override alone
   is insufficient because the native build deliberately rejects a different
   version. Use a release event from a bot or a schedule to detect external
   repository releases; Stiff's own `release` trigger does not observe Bend.
5. Add an optional kernel-verification CI lane with scoped Lean/BendTT, require
   `--verdict`, and distinguish it from ordinary compiler checking. This requires
   additional setup and is not claimed by the local test counts below.

## Upstream issues and repros

No new Bend bug was identified: the namespace, Loc and CLI changes explain the
observed failures. The previously documented LLVM preserve_none issue remains;
see [sanitizer investigation](sanitizers.md). Its mitigation was retained, not
silently broadened.

The new symbolizer warning is reproducible without Stiff or Bend: compile
`int main(void) { return 0; }` with this Apple Clang using
`clang -fsanitize=address,undefined -O1 smoke.c -o smoke`, then run
`env PATH=/nonexistent ./smoke`. It exits 0 but prints "No external symbolizers
found". Running with both `ASAN_OPTIONS` and `UBSAN_OPTIONS` set to
`external_symbolizer_path=/usr/bin/atos` gives clean stderr. This is a tooling
behavior worth reporting to Apple/LLVM if strict empty-PATH launches are expected
without warnings, not a Bend memory fault. No issue was filed during this task.

## Local validation

Validation platform: macOS 27.0 arm64, Apple Clang 21.0.0
(`clang-2100.3.34.2`), Python 3.11.8, libcurl 8.7.1, json-c 0.19 and scoped
libevent 2.2.2-alpha. Tested implementation revision: `7c651bc` (following
`0a082d4`), with documentation changes pending at test time.

- `make setup`, including existing-cache verification: passed.
- `make build`: passed; additional store and validated-api examples compiled.
- Final `make test`: **139 tests, all passed, 300.946 seconds**.
- Final `make test-sanitize`: **142 tests, all passed, 366.778 seconds**.
- `make diagnose-sanitizers`: **6/6 configurations passed**, with clean stderr.
- Kingdom Bend proof/test/CLI check script: passed.
- Independent `--verdict` kernel verification: unavailable (Lean/BendTT absent).

The ordinary suite includes the proof verdict and false-proof rejection;
the sanitizer suite adds deliberate ASan/UBSan fault detectors and the checked
convention-layout assertion. One standalone consumer journey intentionally
fetches its historical public Git revision and Bend 2.0.20; all current-checkout
compiled cases use 2.0.35. The published consumer and BendHub pins must change
only with a corresponding publication, which is outside this task.

All build outputs and raw logs stay under ignored `.cache`; no global install,
push, tag, release or BendHub publication is involved.

[Recorded validation metadata and log hashes](evidence/bend-2.0.35.json) identify
the implementation revision and exact local test runs. Earlier development runs
exposed the stale proof-verdict assertion, missing benchmark symbolizer options,
a consumer setup timeout and one CPU-limit test timeout during overlapping work.
The final suites ran sequentially and passed without weakening the CPU-limit
assertion or disabling sanitizer diagnostics.
