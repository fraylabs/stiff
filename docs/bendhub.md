# BendHub package

Stiff's experimental 0.2.0 library is available as an immutable BendHub package:

```text
0xf5a52e743a7f75c5d624c27c9e0ec81f
```

Use **Bend 2.0.20**. The native effects depend on that compiler's private ABI;
a newer compiler is not automatically compatible. The GitHub
[v0.2.0 release](https://github.com/fraylabs/stiff/releases/tag/v0.2.0) remains
the source for native archives and pinned build tooling.

## Use it

Copy [examples/bendhub-client](../examples/bendhub-client) into your project.
With the [native prerequisites](../README.md#get-started) installed:

```sh
make setup build
# Set STIFF_TOKEN through your shell or secret manager first.
./build/auth-client https://your-api.example/resource
```

The example uses these imports:

```python
import 0xf5a52e743a7f75c5d624c27c9e0ec81f/src/http.bend as Http
import 0xf5a52e743a7f75c5d624c27c9e0ec81f/src/io.bend as Net
import 0xf5a52e743a7f75c5d624c27c9e0ec81f/src/json.bend as Json
```

The same package contains `url`, `server`, `app`, `router`, `schema` and `store`
under `src/`. Import each module directly; importing `stiff.bend` exposes the
package version and checks the collected library, but does not re-export module
aliases. `src/PROOF.bend` and `src/LAWS.bend` are included for explicit proof
checking. Native effects and external dependencies remain trusted code.

BendHub stores Bend and referenced C sources. It does **not** install the native
libraries, compiler or build scripts. The example separately fetches build tools
from GitHub revision `4b20f169249b601d807b2d6aaeddda07a59532a2`, verifies that
revision before building, and keeps the downloaded hub package in `.bend/lib`
using `BEND_LIB`. It does not change your global compiler or package cache.
The library sources match that release; only the package anchor is additive.

Server applications still need the scoped, patched libevent 2.2.2-alpha build;
storage needs SQLite. Client binaries use libcurl and json-c. Runtime has no
Bend/Python dependency. See [dependency pins](dependencies.md).

## Identity and upgrades

BendHub uses content hashes, not a mutable `stiff` name or semantic-version
resolver. Keep the full hash in your imports and the build-tool Git revision in
`stiff.rev`. An upgrade changes those pins explicitly after application tests.
Never assume that an unchanged native toolchain supports a different package,
or that updating Bend is safe for an existing package.

The 17-file package contains the public modules, five C effect files, laws/proofs
and `stiff.bend`, whose comments carry the full MIT license. Examples, test
fixtures, generated binaries, dependency caches and private workspace files are
excluded. The compiler verifies the package hash and each file digest on download, but
trusts existing cached files. The example additionally checks every cached
Bend/C source against its committed `package.manifest` before each build. Treat
the compiler, build tooling and local filesystem as trusted build inputs.
The hash identifies bytes; it is not a proof of native safety or an author identity.

## Verification and reproduction

Run from this checkout after `make setup`:

```sh
python3 scripts/verify-bendhub.py 0xf5a52e743a7f75c5d624c27c9e0ec81f
```

This network-dependent release check creates an empty temporary `BEND_LIB`,
fetches the published package through Bend's loader, verifies the manifest and
all source bytes against this checkout, checks the proof verdict, and compiles
independent HTTPS and notes consumers. It exercises authenticated HTTPS against
a local trusted test certificate and all six persistent application journeys,
including restart, conflicting/concurrent writes, lost acknowledgements,
reconciliation and schema boundaries. Runtime executes with no compiler on PATH.
The temporary consumers and their synthetic state are removed afterwards.
It requires the exact package sources, so use the corresponding source revision
when checking an older package after library changes.

[Publication and download evidence](evidence/0.2.0/bendhub.json) records the
verified hash, compiler and local platform. This package verification adds
macOS arm64 evidence; the existing release's broader platform checks remain
in [the checklist](checklist.md).

To reproduce the package from this source, use the pinned compiler:

```sh
BEND_NO_TELEMETRY=1 .cache/toolchain/bin/bend stiff.bend --publish
```

That last command uploads publicly to BendHub. It is a release operation, not
part of setup or tests. Review the collected sources before publishing a changed
anchor. The package is content-addressed and has no private release channel.
