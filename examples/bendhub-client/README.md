# BendHub authenticated client

Copy this directory outside Stiff, install the native prerequisites listed in
Stiff's README, then run:

```sh
make setup build
./build/auth-client https://your-api.example/resource
```

Set `STIFF_TOKEN` through your shell or secret manager before running. Use HTTPS
for real credentials. The client sends one bearer-authenticated request, prints
the status and JSON `message` field, and exits nonzero on HTTP errors. It does
not follow redirects or retry requests.

`main.bend` imports immutable BendHub sources. `stiff.rev` separately pins the
GitHub checkout used for native build tooling and its checked Bend 2.0.20 and
libevent dependencies. BendHub does not install C libraries or build scripts.
The downloaded checkout also contains sources, but this program imports the
hub package, not those local modules. `make build` stores hub downloads under
`.bend/lib` in this project and checks the build-tool checkout revision. It also verifies every cached Bend/C
file against the committed `package.manifest` before native compilation. Bend
checks hashes on download but trusts cache hits; this extra check detects
altered cached source on subsequent builds. If it fails, inspect the cache
before moving it aside and fetching again.

Keep the hash imports and `stiff.rev` in your application's Git. To upgrade,
review and change both pins and the matching `package.manifest` as needed, preserve the old dependency directory,
and rerun setup plus your application's tests. Do not run `bend update` to
change the compiler beneath these native effects.

Runtime needs libcurl/json-c and a CA trust store; it needs no Bend or Python.
The example's local TLS verification uses only synthetic credentials.
