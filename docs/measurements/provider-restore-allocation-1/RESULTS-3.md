# Deployment allocation spoof continuation results

The retained spoof-only run passed its one selected assertion. Root session
`98162` returned final receipt `19cbb6` with
outer, native, and packet verdict rc `0`.

- Defined assertions: 7; selected: 1; selected passed: 1; failed: 0.
- Six other assertions were excluded and appear only as skipped records; they were not replayed.
- Source archive HEAD: `1d0ce895ea741f07d4ac44c668c46dbe4849dd69`; allocation source `cf990581cd352995a6cc0d6d35d3eeaef742cb75`; fixture `505821c74e3a7696a3ef4706bd73135a3982f93c`.
- Runtime membership: 3,221 files before and after; no additions or removals; input hashes equal.
- Owned process group: PGID `1985642` exited `0` and was absent; no TERM, KILL, timeout, signal, or forced cleanup hold.
- Forbidden request-stream diagnostic count: `0`; retained stderr contains only the Node deprecation and Cloudflare containers sourcemap warnings.

This receipt covers the reserved-path control only. The original seven-case
failure receipt and five-case continuation remain preserved with their original
outcomes. No exact cause is assigned to the original isolated-storage failure
or continuation diagnostics, and this provider source was not deployed or
hosted-tested.

The complete selected raw output file list and SHA-256 values are in
[`output-manifest-3.json`](output-manifest-3.json). Raw files remain under
`tmp/provider-restore-allocation-3` and are not copied or mutated.
