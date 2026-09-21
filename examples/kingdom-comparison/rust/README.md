# Kingdom rules engine in Rust

This is a native Rust implementation of the shared kingdom comparison prompt.
It uses only Rust's standard library. `src/engine.rs` contains command parsing and
the value-to-value state transition; `src/main.rs` is the command-line adapter.

## Build and run

From this directory:

```sh
make build
../../../.cache/kingdom-comparison/rust/kingdom mortgage0 pass1 repay0 buy1
```

The build uses the installed `rustc` directly. All binaries are written below
`../../../.cache/kingdom-comparison/rust`; the source directory receives no
generated files. `make run ARGS="mortgage0 pass1"` is a convenience for simple
shell-safe tokens.

## Tests and checked scope

Run:

```sh
make test
```

The engine tests enumerate all 80,088 states whose three gold balances are
nonnegative and total 140, across both owners, mortgage values, and turns. For
each state they compare all eight valid command tokens with a separately written
contract oracle (640,704 transition cases), check gold preservation, accepted
turn changes, and exact rejection identity. Additional tests cover the initial
state and representative invalid tokens. Native process tests check exact stdout,
empty-argument behavior, normal exit status, mixed accepted/rejected sequences,
whitespace/casing errors, and non-UTF-8 arguments on Unix.

These are finite executable tests, not proofs. They do not formally verify the
compiler, operating system, process I/O, or the correspondence between the test
oracle and the English prompt. Invalid strings are an unbounded set, so the tests
sample them while the implementation rejects them through an exact eight-token
match. Arithmetic safety relies on the private initial state and transitions:
the public API cannot construct arbitrary balances, and every transition is
covered over the full total-140 state model by the enumeration described above.
