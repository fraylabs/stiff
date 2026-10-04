# Kingdom rules engine — Bend 2

The current checkout builds with Bend 2.0.35. Historical comparison evidence
records 2.0.20. The native CLI now skips the executable-name argument.

This directory contains the Bend implementation of the shared kingdom comparison
task. `engine.bend` contains command parsing and the pure state transition. The
small `main.bend` module owns argument IO and line rendering.

From the Stiff repository root, build and run the native executable with the
pinned compiler and existing native build script:

```sh
./scripts/build-native.sh \
  examples/kingdom-comparison/bend/main.bend \
  .cache/kingdom-comparison/bend/kingdom
./.cache/kingdom-comparison/bend/kingdom mortgage0 pass1 repay0 buy1
```

Run every supplied check with:

```sh
./examples/kingdom-comparison/bend/test.sh
```

The check script type-checks all laws in `LAWS.bend`/`PROOF.bend`, builds and
runs the Bend-native test program, builds the CLI, and checks exact output for
accepted commands, rejected commands, invalid spelling, and the empty argument
list. The runtime test program checks focused examples for every operation and
walks every sequence of nine parsed command variants through depth six from the
initial state. At every explored step it checks total gold, owner/turn bounds,
turn changes after acceptance, and full state identity after rejection.

The checked laws establish the exact initial state, invalid-command identity,
both pass transitions, and rejection of all non-pass operations on the wrong
turn for arbitrary field values. They do not prove the complete rules engine,
gold conservation for every possible state, parser/renderer correctness, the C
backend, or the compiler. The sequence walk and focused checks are finite tests,
not proofs. The state is private to this program and every reachable balance is
small, so U32 overflow is not reachable; that fact is tested only through the
bounded sequence walk and is not formally proved.
