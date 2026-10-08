# Pinned native dependencies

`make setup` installs Bend 2.0.36 and builds libevent 2.2.2-alpha inside `.cache`.
It verifies release archive SHA-256 values before extraction. It does not change
system packages, global compiler installations or services. Python, CMake and patch are
build tools only; applications run as native executables.

Bend source revision: `ae1101ca7d15364f9274fa6b1367d175884a7da7`.
The four release archive hashes are pinned in `scripts/setup.py` and come from
[the upstream 2.0.36 release](https://github.com/bendlang/bend/releases/tag/v2.0.36).

The exact download URLs, source revisions, tag object and checksums are maintained
in `scripts/setup.py` and `scripts/setup-libevent.py`. The libevent build is static,
position independent, with its OpenSSL/mbedTLS backends disabled. Stiff's HTTP server
uses a reverse proxy for TLS; the HTTP(S) client retains libcurl's normal TLS
verification. libcurl, json-c and SQLite remain system dependencies.

The 2.2 libevent API supplies the public pre-body request hook needed for incremental
uploads. This is an **alpha dependency**, deliberately pinned and tested; the Stiff
release does not reclassify it as stable. The older system libevent is not used for
server builds. Its headers/libraries remain untouched. See the source/security
references and exact streaming contract in [streaming.md](streaming.md).

Setup verifies an existing cache before reusing it and refuses mismatched metadata,
headers, licenses or missing static libraries. Build scripts require the scoped
version and required public APIs rather than silently falling back to a different
system library. Source archives and generated binaries remain ignored by Git.

Third-party license notices are preserved under `licenses/` and included in
packaged examples. Package and benchmark manifests record the actual libevent pin;
they do not report the unrelated system pkg-config version as the linked version.

Upgrade dependencies in a fresh checkout, update the explicit pins, verify normal
and sanitizer suites across the platform matrix, rerun lifecycle/framing/upload
failure tests, and inspect the resulting binary's linked libraries. Preserve the
old executable and compatible data until the application upgrade is accepted.

The tracked `patches/libevent-error-headers.patch` preserves headers set by a
successful custom error callback, so parser errors retain Stiff’s JSON content
type. Setup checks both the patch and resulting source hashes. The dependency
manifest records this modification; example archives include the patch.

When upgrading an existing checkout, move `.cache/toolchain` to a versioned
backup (for example `.cache/toolchain-2.0.20`) before `make setup`. Setup refuses
to overwrite a compiler with a different checksum. Keep the backup for rollback.
