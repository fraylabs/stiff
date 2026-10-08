# @NAME@: a proven Stiff API

With Stiff's native prerequisites installed (see its README):

```sh
make setup check build
make run                     # loopback :8080; Ctrl-C to stop
curl -fsS http://127.0.0.1:8080/hello
# hello from @NAME@
make mistakes                # ordinary code checks; hello_contract fails
```

One route, one law: `GET /hello` returns exactly HTTP 200 and the greeting,
preserving any modeled natural-number state. Edit `api.bend`, then adapt
`PROOF.bend` to express your promises. `make build` always checks both Stiff's
framework laws and your application law and requires `ALL PROOFS CHECK`.
Compiling `main.bend` directly bypasses the gate.

`stiff.rev` pins an exact MIT Stiff 0.6.1 revision. Setup fetches it into
`deps/stiff`, then installs checksum-pinned Bend 2.0.36 and scoped libevent.
With `STIFF_CACHE`, it shares libevent and reuses only a compiler whose checksum
matches that published revision; otherwise setup installs its own pinned compiler.
No global install. Use a destination path without spaces for native builds. With an existing compatible Stiff cache, use
`STIFF_CACHE=/absolute/path/to/stiff/.cache make setup` to reuse its compiler
and libevent via symlinks; setup verifies the pins. Don't edit that shared cache.
Set `STIFF_HEAVY_LOCK` to a directory path to serialize builds across projects
on one machine; by default no lock is used. Python runs tooling only; deployment needs just the native
binary and its system libraries. `PORT=0 make run` chooses an available port.

The law covers a pure decision, not native memory safety, response encoding,
HTTP transport, compiler/runtime or OS. The effect edge renders the pure
decision; errors before dispatch are outside the law. There is no authentication
or persistence in this minimal template. Add storage at the edge and include
the complete application state in your laws, as the bookings and ledger
examples do. Every additional route needs its own promises and status laws.

`make mistakes` copies the pure files under `build/mistake`, changes the
greeting and requires a failed `hello_contract` verdict; it builds no mutant
binary and leaves your source untouched. To see the build gate yourself,
change `hello from @NAME@` to `goodbye from @NAME@` in `api.bend` and run
`make build`: it must fail before compilation. Restore the greeting afterward.
