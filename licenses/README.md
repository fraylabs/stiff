# Third-party notices

Stiff's own source is MIT, as stated in the root LICENSE.

Compiled executables include Bend's generated runtime. The pinned Bend 2.0.35
source revision is `79df8d9c40722ee9507a1e253f283b51025f9d6c`; its Apache 2.0
license is preserved in `Bend-Apache-2.0.txt`. Stiff's sanitizer build changes the
generated calling-convention annotations as documented in docs/sanitizers.md.
The upstream runtime has not been relicensed under Stiff's MIT license.

System libcurl, json-c and SQLite retain their upstream licenses. The package
manifest records linked versions; system-library distribution remains separate.
Pinned libevent's license is included when its static library is bundled into
the example executable. Dependency source archives/build outputs remain ignored.

The bundled libevent includes the error-header modification recorded in
`patches/libevent-error-headers.patch` and the package dependency manifest.
