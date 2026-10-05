# Recorded comparison — September 22, 2026

**Both implementations passed the 165 game-command scenarios. An expanded CLI
check found three Bend runtime-argument mismatches against the literal prompt;
Rust passed those cases. Bend's proofs caught a specified turn-rule regression,
but did not catch an unproved accounting regression. Tests caught both deliberate
regressions in both implementations.**

This is one paired run on macOS arm64, using Bend 2.0.20 and rustc 1.95.0
(59807616e, 2026-04-14). It does not establish which language is generally better.

## What each agent received

Two fresh agent contexts used the same AI model and settings. Both read [PROMPT.md](PROMPT.md), with only their assigned
language, owned directory and toolchain instructions differing. Both read the
same repository/execution instructions, could use their language's standard
library and installed compiler, and were prohibited from reading the other
implementation or the independent checker. The repository already contains
Bend examples, so this was not a controlled training/context-equivalence study.
There was no fixed time/token budget or repeated random trial.

The parent wrote the reference model before reading either implementation. No
implementation-specific correction from the parent was required to pass the
comparison. The workers' worklogs retain their own failed checks and fixes.
After the first independent comparison passed, the Bend worker was told that
result while finishing documentation, without receiving the reference code.

## Delivered checks

| Evidence | Bend 2 | Rust |
| --- | --- | --- |
| Independent native CLI comparison | 165 scenarios, 4,094 state lines, all matched | Same scenarios and lines, all matched |
| Reserved runtime-argument scenarios | 3 mismatches against literal prompt | All 3 passed |
| Reachable-state transition coverage | All 8 reachable states × 19 command classes | Same |
| Worker tests | Focused rules, exact CLI snapshots, nine parsed command variants through depth 6 | 3 engine tests and 4 CLI tests; 640,704 state/action cases covering all 80,088 total-140 model states |
| Compiler-checked game laws | 10 laws, described below | None supplied |
| Ordinary compiler checks | Bend's type/usage/termination checks | Rust's type/borrow checks; warnings denied |

The 19 command classes comprise eight accepted spellings and eleven invalid
examples. Longer seeded histories add traversal and output coverage. This does
not exhaust every possible invalid string or arbitrary-length execution.
The Rust worker also tested non-UTF-8 Unix arguments; the shared parent comparison
uses Unicode command strings and makes no cross-language raw-argv claim.

The Bend laws prove the initial state, invalid-command identity, the exact two
pass transitions, and six wrong-turn rejections (buy/mortgage/repay for each
player). The parameterized laws apply to arbitrary field values as written.
They **do not prove** gold conservation, every ownership/mortgage restriction,
all successful transfers, general rejection identity, the parser, CLI, compiler,
or native runtime. The pass laws cover their particular turn transitions,
not every successful action's turn behavior.

Rust's enum types restrict owner/turn values; private state fields constrain
construction through its public module API. That is useful type/API structure,
not a proof of the money-transfer rules. Its enumeration is broader in state
coverage than the supplied Bend runtime tests, but remains executable testing.

## Actual CLI boundary mismatch

The parent expanded evaluation after the workers delivered. For ordinary game
commands and sampled invalid strings, both outputs matched. But the native Bend
runtime processes options before `IO.args()`:

- Invoking with `--` produces no game output instead of one error line.
- Invoking with `--threads 2` consumes both tokens instead of producing two errors.
- Invoking with `-- pass0` produces the move line but omits the delimiter's error.

Rust treats all these raw tokens as game arguments and matches the literal shared
prompt. These are real differences, not proof-checker failures: argv processing
is outside the supplied game laws. The strict expanded comparison exits 1 with
three Bend failures; see [runtime-boundaries.json](evidence/runtime-boundaries.json).
Reproduce it by adding `--include-runtime-flags` to the `compare.py` invocation.

For normal use, Bend's runtime delimiter can pass option-looking strings to the
game (`kingdom -- --threads 2`). That workaround does not make the original raw
CLI contracts identical. We preserved the independently delivered implementations
and the unchanged prompt rather than silently changing either to hide the gap.

## Deliberate mistakes in temporary copies

The original sources were preserved. [mutations.py](mutations.py) introduced two
faults and reran ordinary compilation, the delivered Bend proofs, worker tests,
and independently calculated CLI examples.

| Deliberate fault | Bend ordinary compile | Bend delivered proofs | Rust ordinary compile | Worker tests in both |
| --- | --- | --- | --- | --- |
| Accept a pass but keep the same turn | Accepted | **Rejected** at `pass0_changes_only_turn` | Accepted | **Rejected** |
| Credit 6 gold on a mortgage, debit bank by 5 | Accepted | **Accepted**: no corresponding law | Accepted | **Rejected** |

The first fault shows an actual additional guarantee from a checked Bend law.
The second shows why a generic “proofs passed” message is not a bug-free claim.
A conservation law could be added in Bend; verification tools could also be used
with Rust. This run measures the artifacts these agents produced with the given
prompt, not the maximum verification power of either ecosystem.

The application entry point does not import `PROOF.bend`, so building only
`main.bend` does not check those laws. The supplied `test.sh` and top-level
comparison `make test` explicitly check them. Preserve that check when changing
the example.

## Development experience observed

The Rust implementation compiled and passed its first functional test run. A
formatting check failed, was fixed, and passed on rerun. The Bend implementation
needed corrections for proof-definition syntax, affine parameter reuse, recursive
helper/declaration structure, ordering of the decreasing recursive argument and
a CLI match expression. Its final proof, native test and CLI checks passed.
See [Bend worklog](bend/WORKLOG.md) and [Rust worklog](rust/WORKLOG.md).

The parent mutation runner initially selected an executable name colliding with
Rust's `tests/` directory; that harness error was corrected before recording the
results. It was not an implementation failure.

## What this supports

For ordinary game commands, both agents delivered the requested behavior. The
Bend CLI does not fully meet the prompt for reserved runtime tokens. Bend added
checked guarantees for some explicitly stated rules, and required more recorded
compiler-related revisions in this run. Rust supplied broader finite-state tests.
There is no evidence here that either complete implementation is bug-free, or
that proving a complicated game's entire rules engine will be easy.

This example has no networking, persistence, UI, concurrency or user authentication.
It is a rules-engine comparison under Stiff's examples, not a deployed multiplayer
game. Stiff's separate 138-test regression suite passed; no framework implementation
or dependency pin was changed.

Raw reproducible evidence: [comparison.json](evidence/comparison.json),
[mutations.json](evidence/mutations.json), [runtime-boundaries.json](evidence/runtime-boundaries.json),
and [verification.json](evidence/verification.json).
Generated C and executables stay in the ignored `.cache/kingdom-comparison/` tree.
