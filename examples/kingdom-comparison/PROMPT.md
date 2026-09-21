# Shared implementation task

Build a native command-line rules engine for a tiny two-player kingdom game.
Implement in your assigned language and directory. The language/directory are
provided separately; all functional requirements and evaluation criteria here
are identical for both implementations. Use only the language's standard library.
No network, external packages, new native effects, credentials or service changes.

Initial state: player 0 gold=20; player 1 gold=20; bank gold=100; a single parcel
owned by player 0; parcel not mortgaged; current turn=0. Gold consists of whole
nonnegative units. Total gold across the players and bank must stay exactly 140.

The program takes a sequence of command tokens as positional CLI arguments.
For each command, process it and print exactly one line with seven space-separated
fields: status gold0 gold1 bank owner mortgaged turn. Status is `ok` or `error`;
all other fields are decimal integers; mortgaged is 0 or 1. Print no initial line.
No arguments prints nothing and exits successfully. Invalid commands produce an
error state line, not a process error. Normal gameplay exits 0. No debug stdout.

Commands are exactly buy0, buy1, mortgage0, mortgage1, repay0, repay1, pass0, pass1.
The final digit is the actor. Every accepted command, including pass, changes the
turn to the other player. Every rejected command preserves the entire state,
including the turn. Commands from the wrong player are rejected.

- buy: actor must not own the parcel, parcel must not be mortgaged, actor must
  have at least 10 gold. Transfer 10 gold from actor to current owner and change
  parcel ownership to actor. Bank unchanged.
- mortgage: actor must own an unmortgaged parcel, bank must have at least 5 gold.
  Transfer 5 gold from bank to actor and mark the parcel mortgaged. Owner unchanged.
- repay: actor must own a mortgaged parcel and have at least 5 gold. Transfer 5 gold
  from actor to bank and clear the mortgage. Owner unchanged.
- pass: no other condition beyond correct turn; monetary/parcel state unchanged.
- Anything else (including other casing, whitespace or actor digits) is invalid.

Deliver readable source with separated pure transition logic and CLI IO, plus
README build/run instructions, tests, and an honest account of what is checked.
Use language-native mechanisms available in the installed toolchain. Establish
as much as practical about preservation of gold, ownership/mortgage restrictions,
rejection identity and turn changes. Never label tests as proofs. If using formal
laws, implement checked proofs without TODOs, assumptions, unsafe escape hatches,
or weakening the contract. Clearly identify which properties remain unproved.
Do not change this prompt. Do not read the other implementation or its reports.
Do not claim universal correctness from a finite test. Keep an honest short
WORKLOG.md of compiler issues, failed checks, and revisions you actually make.

The parent will independently test sequences against this specification, inspect
proof coverage, compare output behavior and record limitations. This is a single
paired implementation exercise, not a statistically controlled language benchmark.
