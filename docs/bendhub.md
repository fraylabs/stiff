# BendHub package

Stiff's experimental 0.4.0 library is available as an immutable BendHub package:

```text
0x4ee0ec16258e9b8ad6ef37e5b8c4f95e
```

This published hash requires **Bend 2.0.35**, matching the current Git checkout.
The native effects depend on its private compiler ABI; a newer compiler is not
automatically compatible. The GitHub
[v0.4.0 release](https://github.com/fraylabs/stiff/releases/tag/v0.4.0) provides
native archives and pinned build tooling. The historical 0.2.0 package remains
immutable and requires Bend 2.0.20.

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
import 0x4ee0ec16258e9b8ad6ef37e5b8c4f95e/src/http.bend as Http
import 0x4ee0ec16258e9b8ad6ef37e5b8c4f95e/src/io.bend as Net
import 0x4ee0ec16258e9b8ad6ef37e5b8c4f95e/src/json.bend as Json
```

The same package contains `url`, `server`, `app`, `router`, `schema`, `store`
and pure `contracts` under `src/`. Import each module directly; importing `stiff.bend` exposes the
package version and checks the collected library, but does not re-export module
aliases. `src/PROOF.bend` and `src/LAWS.bend` are included for explicit proof
checking. Native effects and external dependencies remain trusted code.

BendHub stores Bend and referenced C sources. It does **not** install the native
libraries, compiler or build scripts. The example separately fetches build tools
from GitHub revision `be078621ad69303546de258fd8db578fc8c9b0f6`, verifies that
revision before building, and keeps the downloaded hub package in `.bend/lib`
using `BEND_LIB`. It does not change your global compiler or package cache.
The library, compiler pin and native build scripts match the tagged release;
subsequent release commits add consumer pins, documentation and evidence.

Server applications still need the scoped, patched libevent 2.2.2-alpha build;
storage needs SQLite. Client binaries use libcurl and json-c. Runtime has no
Bend/Python dependency. See [dependency pins](dependencies.md).

## Identity and upgrades

BendHub uses content hashes, not a mutable `stiff` name or semantic-version
resolver. Keep the full hash in your imports and the build-tool Git revision in
`stiff.rev`. An upgrade changes those pins explicitly after application tests.
Never assume that an unchanged native toolchain supports a different package,
or that updating Bend is safe for an existing package.

The 20-file package contains the public modules, five C effect files, laws/proofs
and `stiff.bend`, whose comments carry the full MIT license. Bend 2.0.35 also
includes the standalone `LICENSE` file in the manifest. Examples, test
fixtures, generated binaries, dependency caches and private workspace files are
excluded. The compiler verifies the package hash and each file digest on download, but
trusts existing cached files. The example additionally checks every cached
Bend/C source against its committed `package.manifest` before each build. Treat
the compiler, build tooling and local filesystem as trusted build inputs.
The hash identifies bytes; it is not a proof of native safety or an author identity.

## Verification and reproduction

Run from this checkout after `make setup`:

```sh
python3 scripts/verify-bendhub.py 0x4ee0ec16258e9b8ad6ef37e5b8c4f95e
```

This network-dependent release check creates an empty temporary `BEND_LIB`,
fetches the published package through Bend's loader during C emission (without
executing it), verifies the manifest and all source bytes against this checkout,
checks the pure `src/PROOF.bend` verdict with `--check-only`, and compiles
independent HTTPS and notes consumers. It exercises authenticated HTTPS against
a local trusted test certificate and all six persistent application journeys,
including restart, conflicting/concurrent writes, lost acknowledgements,
reconciliation and schema boundaries. Runtime executes with no compiler on PATH.
The temporary consumers and their synthetic state are removed afterwards.
It requires the exact package sources, so use the corresponding source revision
when checking an older package after library changes.

[Publication and download evidence](evidence/0.4.0/bendhub.json) records the
verified hash, compiler and local platform. This package verification adds
macOS arm64 evidence; the broader platform checks are linked
from [the checklist](checklist.md).

To reproduce the package from this source, use the pinned compiler:

```sh
BEND_NO_TELEMETRY=1 .cache/toolchain/bin/bend stiff.bend --publish
```

That last command uploads publicly to BendHub. It is a release operation, not
part of setup or tests. Review the collected sources before publishing a changed
anchor. The package is content-addressed and has no private release channel.
