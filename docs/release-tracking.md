# Tracking Bend releases and first use

The supported compiler remains Bend 2.0.35. `.github/workflows/check.yml` is
unchanged by the tracking work. `bend-latest.yml` resolves GitHub's newest non-prerelease Bend release
once per daily run (03:23 UTC) or manual dispatch, then tests Linux x64 and macOS
arm64 with normal and combined sanitizer profiles. Both use the complete suite,
including `src/PROOF.bend` verdict checking and false-proof rejection.

The tracking job checks out the exact Stiff commit in a disposable runner.
`scripts/prepare-bend-candidate.py` changes only exact-version expectations in
that copy's native build, package manifest/test and diagnostic script. It does
not change the supported pin, production layouts, published consumer revision
or BendHub package. Do not run this helper in your working checkout.

`python3 scripts/setup.py --release-tracking-version X.Y.Z` opts into candidate
installation. Ordinary `make setup` still uses the four repository-pinned
SHA-256 values. Candidate setup prefers a matching release `.sha256` file or
SHA256SUMS/checksums asset, then GitHub's release-asset SHA-256 digest. If neither
exists, it prints **WARNING: UNPINNED**, hashes the downloaded bytes and records
`integrity: unpinned`. A published malformed checksum fails rather than silently
falling back. Unpinned candidate caches cannot be reused. Archive mismatches,
missing platform assets and unexpected executable versions fail installation.

`.cache/toolchain/.release-metadata.json` records version, target, upstream
release URL, source commitish, integrity policy and actual archive SHA-256.
A source commitish may be a branch rather than an immutable source revision;
it is labeled accordingly. Every test job's summary names the Bend version,
platform/profile and final status, includes this metadata when available, and
shows the end of the suite log. Full setup/test logs remain in Actions step
logs. No automatic pin upgrade or publication is performed. Scheduled workflows run from GitHub's default branch. This workflow is now on
`main`; pinned Check run [37201714690](https://github.com/fraylabs/stiff/actions/runs/37201714690)
and latest-Bend run [37201729044](https://github.com/fraylabs/stiff/actions/runs/37201729044)
passed on `63a0ca1` with Bend 2.0.35 (eight pinned jobs and four candidate test
jobs plus resolution). Final release evidence is in [0.3.0](evidence/0.3.0/).

## ABI checks

All five native effect modules check reachable marshaled constructor arities at
startup. This covers raw HttpOk (3), Received (6), StreamReceived (5), Metrics
(10), JSON boxes/scalars, server config/reply/header, URL and store layouts,
plus shared list/string/tuple shapes where used. HttpOk's raw construction also
requires non-hot metadata. Other constructors' hot flags vary with compiler
specialization and are not pinned to one value. These checks do not establish
field order/type or ownership correctness; actual compiled HTTP, JSON, server,
streaming and store journeys remain necessary. Input records declared in a
different Bend module cannot be named by local `CID(Name)` checks here and are
covered by those journeys.

A negative compiled test changes the generated HttpOk descriptor's arity and
hot flag separately and requires an explicit Stiff ABI error before HTTP IO.
The candidate integrity tests cover checksum preference, GitHub digests,
unpinned warnings and rejection of malformed checksum metadata.

## Historical local verification and quickstart

Platform: macOS 27 arm64, Apple Clang 21.0.0. No global installs, pushes, tags,
releases or BendHub publication were performed. Raw logs stay in ignored
`.cache/release-tracking`; [committed evidence](evidence/release-tracking.json)
contains timings, source/log hashes and candidate provenance.

### Timed README walkthrough

The original README was followed literally in a fresh temporary public clone,
with an empty HOME and a minimal explicit PATH (existing Python 3.11.8 and native
tools). Clone took 1.036 seconds and setup 72.970 seconds. `make test` took
698.479 seconds and failed its CPU-limit test's five-second wall timeout on this
busy host: 139 tests, one error. The full path stopped after **772.489 seconds
(12 minutes 52 seconds)**, before `make build` or its external httpbin request.
It contained no server-start command in Get started.

The final server-first steps were followed in another fresh clone/empty HOME,
with no existing Stiff compiler or libevent cache. Because this branch is not
published, only repository source was overlaid from the local branch after
cloning; no cache was copied. Native prerequisites were already installed, so
no `brew install`, apt or Xcode installation was performed. Python 3.14.7 was
selected via the documented Homebrew PATH, and the documented curl/SQLite
pkg-config exports were applied. The measured total includes cloning, source
overlay, environment commands, setup, compilation and a successful local curl
health request:

| Step | Seconds |
| --- | ---: |
| Public clone | 2.769 |
| `make setup` (cold compiler and libevent) | 176.088 |
| `make server` | 11.800 |
| Total through healthy HTTP response, including environment commands | **226.235** |

The server returned `{"message":"healthy"}` on port 8080 and exited 0 after
SIGINT. This demonstrates **3 minutes 46 seconds with native prerequisites
installed**, not a five-minute bare-OS installation claim. Ubuntu execution and
installing system prerequisites from scratch were not measured locally.

Snags addressed:

- The full test suite was on the critical path; it is now a separate verification
  step after first use. Its CPU-limit timeout is recorded, not counted as a pass.
  The harness now allows 20 wall seconds to consume its unchanged one-second
  kernel CPU budget, and includes captured diagnostics on an unexpected exit.
  A focused run consumed 6.61 wall seconds before the expected signal; the
  updated focused test passed.
- Get started built a client, not a server, and required an external httpbin
  service. It now starts the server and checks a local health route.
- Dependency names were given without installation commands. macOS and Ubuntu
  24.04 now have concrete commands, including curl for the health check.
- macOS can select Apple's old Python or miss keg-only curl/SQLite metadata.
  The PATH and PKG_CONFIG_PATH exports are explicit, and setup checks Python,
  native tools and library versions before downloads/builds.
- The official Bend installer may install a different version. It is mentioned
  alongside the supported scoped, pinned `make setup` path.
- The initial draft's health response example was corrected to the server's
  actual message before the final timed run. No stale affirmative Node-hosted
  descriptions were found in the tracked repository; current native descriptions
  and historical comparisons were preserved.

### Workflow validation

- `actionlint` 1.7.12 passed on the new workflow. The workflow's actual resolver
  shell/Python step was executed locally and produced `version=2.0.35` plus the
  expected linked summary. Its reporting step was also executed with the
  preserved failed run and required the Bend version, failure status and
  archive provenance in the resulting summary. No `act` execution was possible:
  Docker's daemon was
  unavailable. Linux x64 and GitHub-hosted runner execution remain unverified
  locally.
- A disposable source checkout ran candidate preparation, fresh compiler
  download and setup, then normal and sanitizer suites sequentially. Only the
  already-verified pinned libevent build was reused and its pkg-config prefix
  relocated; the compiler cache was empty and downloaded from the release.
  The candidate was the newest release **2.0.35**, so this also checks the
  supported version. API metadata recorded source
  `79df8d9c40722ee9507a1e253f283b51025f9d6c` and macOS arm64 archive SHA-256
  `2582f25057a519c330e6875798b784b727d4201f1c1f6944a105348f0eb8972e`.
- Final normal suite: **147 tests passed, 486.974 seconds**. This includes proof
  verdict/negative proof, descriptor corruption, checksum policy and real native
  HTTP/HTTPS/server/streaming/store journeys.
- Final combined sanitizer suite: **150 tests passed, 382.213 seconds**,
  including deliberate ASan/UBSan fault detectors and the checked convention
  layout. The workflow's actual reporting script also produced verified success
  summaries for both profiles, with version, provenance and suite verdict.
- Pinned `make setup` also passed and `.github/workflows/check.yml` was confirmed
  byte-for-byte unchanged. The standalone ABI negative test and all seven
  candidate integrity tests passed independently.

The initial candidate normal run had 147 tests and one CPU-limit failure:
supervisor exit 125 (setup failure). Its old assertion did not include captured
stderr, so the underlying cause could not be established. The final focused and
normal CPU-limit checks passed. The harness change addresses the separately
observed wall timeout and retains diagnostics; it does not claim to fix that
unexplained exit 125. No supervisor runtime logic or expected signals changed.
