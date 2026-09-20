# Stiff

Stiff is an experimental open-source Bend 2 networking library. Keep changes
self-contained in this repository and preserve the exact compiler pin until an
upgrade is explicitly tested. Do not copy private product code, data or history.

- Read README.md for the current support boundary.
- Run `npm run setup`, then `npm test` after changing code or laws.
- Keep `src/PROOF.bend` in the test path; compiling an application alone is not a
  substitute for checking laws.
- Treat the Node transport, codec and Bend compiler as trusted implementation,
  not formally verified code.
- Do not disable TLS validation or introduce implicit retries of side effects.
- Keep generated compiler sources, test certificates and build outputs ignored.
- The Bend IO runner supports only the effects listed in README.md. Keep its
  compiler-internal integration in `src/runner.mjs`; cover changes with real
  `.bend` programs and retain explicit failure for unsupported effects.
- Native effects are an experimental CPU backend using libcurl/json-c. Run
  `npm run test:native` after changing native code or the Bend-facing types.
  Constructor packing is pinned compiler ABI, not a stable public interface.
- See docs/native.md for numeric/Unicode limits and the reproduced upstream
  sanitizer failure. Do not claim sanitizer verification or static portability.
