# Provider worker deploy dry-run — run 1

The local Wrangler dry-run completed successfully and produced the expected three-file bundle. It did not upload or deploy anything.

- Child exit: `0`; verdict exit: `0`; timeout/signal: none
- Bundle: `index.js` 207,972 bytes (`ed08567f…`), `index.js.map` 322,953 bytes (`a7fa5b39…`), `README.md` 116 bytes (`fb23cb7b…`)
- Metafile SHA256: `7aba08c1b25ade779b7fbdb8a32dc4bc69f418a03be58d512a9afd50e4da21e6`
- Observed bindings: three Durable Objects (`COMMONPLACE_LOG`, `REALM_CONTAINER`, `REALM_NODE`), KV `REALM_REGISTRY` `98aa81a3f3e644d6a6893eeefdd779d5`, and `REALM_TEST_LEVERS=1`

Input hashes were pre/post equal across 3,361 files. The runtime inventory remained at 3,221 with no additions or removals. Process group `2101114` exited absent with no TERM, KILL, signal, or timeout. Stderr contained only the Node `punycode` deprecation warning.

The command path used Wrangler `deploy --dry-run` with upload disabled; it reported the configured container but did not invoke Docker. This evidence does not include network monitoring, live preservation checks, or a deployment claim. `OUTPUT-MANIFEST-1.json` hashes all retained regular output files without following the runtime symlink.
