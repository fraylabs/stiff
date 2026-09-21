# Kingdom rules: Bend 2 and Rust

Two independent agents received the same [task prompt](PROMPT.md), with the
language and output directory supplied separately. Both used `gpt-5.6-sol` at
high reasoning effort with fresh task contexts. Neither was allowed to inspect
the other's implementation or the parent's independent reference model.

The game has two players, one parcel, gold, a bank and alternating turns. Players
can buy the parcel, mortgage it, repay its loan or pass. You cannot sell mortgaged
land, act out of turn, or spend money you lack. This intentionally small engine
makes the rules and verification boundaries inspectable. It is a local CLI
example, not the proposed multiplayer game or a Stiff HTTP application yet.

From the Stiff root, after `make setup` and with `rustc` installed:

```sh
make -C examples/kingdom-comparison test
```

This builds both native executables, runs their own checks, then compares them
against the independent reference for game commands. See [RESULTS.md](RESULTS.md)
for the recorded outcome and proof boundaries. The broader raw-CLI comparison
(`compare.py --include-runtime-flags` with the same binary arguments) intentionally
reports three known Bend runtime-option mismatches against the literal prompt;
these independently delivered outputs are retained for inspection.

Each native binary accepts command tokens and reports the result after each one:

```text
mortgage0 buy1 pass1 repay0 buy1

ok 25 20 95 0 1 1
error 25 20 95 0 1 1
ok 25 20 95 0 1 0
ok 20 20 100 0 0 1
ok 30 10 100 1 0 0
```

Fields are `status gold0 gold1 bank owner mortgaged turn`.
Player 1's first purchase fails because the land is mortgaged; after a pass and
repayment it succeeds. The rejected command changes neither money nor turn.

## Comparison method

The parent wrote [compare.py](compare.py) directly from the prompt before reading
either implementation. It constructs every state reachable from the specified
initial state, tests all eight commands and eleven invalid-token examples from
each, and adds twelve seeded histories of 300 commands each. Both programs must
match the reference output exactly, exit successfully and emit no stderr.

There are only eight reachable states in this deliberately bounded game. That
lets us cover the reference model's complete one-step transition table, but does
not prove arbitrary-length execution, all possible invalid strings, arbitrary
initial states, compiler correctness or correctness of the reference model.
Some specified insufficient-funds checks cannot be reached from this initial
state; implementation-level tests/proofs must be assessed separately.

Run the workers' build/test instructions in `bend/README.md` and `rust/README.md`,
then run the comparison with their native executable paths:

```sh
python3 examples/kingdom-comparison/compare.py --bend PATH_TO_BEND_BINARY --rust PATH_TO_RUST_BINARY
```

Tests, compiler rejection and checked proofs are reported separately. A proof
about one helper is not automatically a proof about every CLI action or the
whole game. Both compiler/runtime implementations remain trusted. This single
paired run is an example to inspect, not evidence that either language is
universally better or that proved code is bug-free.

## Deliberate mistakes

After both workers deliver, `mutations.py` makes temporary copies and tries two
changes: accepting a pass without changing the turn, and giving a mortgaging
player six gold while deducting only five from the bank. It checks ordinary
compilation, the delivered Bend laws, the workers' tests, and independently
calculated expected CLI output. It never edits the delivered implementations.

```sh
python3 examples/kingdom-comparison/mutations.py
```

This checks whether the existing proofs cover these particular regressions.
A mistake escaping those proofs means a missing specification/proof obligation,
not that Bend cannot express it. Conversely, passing the tests does not imply
that Rust or Bend has established every desired rule.
