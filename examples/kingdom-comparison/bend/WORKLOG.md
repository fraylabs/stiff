# Worklog

- Read the shared prompt, repository instructions, Bend 2.0.20 guide, and the
  relevant Base definitions before implementation.
- Chose a pure algebraic transition module with a separate CLI module. Added
  checked structural laws and a native Bend test runner with bounded exhaustive
  reachable-sequence checks.
- The first proof check failed because a zero-argument proof definition still
  requires `()` before its return body. Corrected that syntax and reran the
  checker.
- The next check exposed Bend's affine default for helper parameters reused in
  both predicates and returned states. Marked those primitive inputs reusable;
  no rule behavior changed.
- The first native-test build found the same issue in test-only invariant code.
  Avoided reconstructing a state just to sum its balances and marked an accepted
  successor reusable for its two independent checks.
- Bend required a declaration before mutually recursive test helpers, but then
  rejected live code calling the still-open declaration. Folded the nine command
  branches into a single self-recursive explorer instead.
- Bend checks recursive arguments from left to right, so the changing state hid
  the decreasing depth argument. Reordered the explorer to put depth first.
- The native tests then built and passed. The separate CLI build rejected a
  direct match on a computed transition. Extracted its fields through pure
  accessors instead, avoiding a mutually recursive IO helper.
- The complete check script passed on Bend 2.0.20. Additional native CLI runs
  confirmed exact rejection lines and exit status 0 for uppercase, empty,
  leading/trailing-space, embedded-newline, extra-digit, and `--bad` tokens
  (using the runtime's `--` argument delimiter for the last case).
