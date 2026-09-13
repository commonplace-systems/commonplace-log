# Deployment allocation initial-run results

The retained root run is an incomplete failure receipt. Root session `56875` ended with final receipt `b527b2` and outer rc `125`; native rc was `1` and the packet verdict was `125`.

- Suite: 7 tests defined; 2 passed, 2 failed, and 3 remained unconsumed after the isolated-storage failure.
- Passed: the idempotent retry and conflicting-operation/secret cases.
- Failed: the legacy-create refusal and bearer-authorization cases. The retained stderr reports an isolated-storage cleanup assertion where `.sqlite-shm` was found while `.sqlite` was expected. This receipt does not assign a cause beyond that observation.
- Source archive HEAD: `c4c7e246b611b8a43c9bce6b4a7aa95eda10e1ea`; fixture commit `cb490e6158e9011ea9d3193c0aa00eead457e5a5` with SHA-256 `09830b29a16ecee8a4a80cbeedfbce4c67b7e025af1f9fa136cce5651b535c24`.
- Runtime membership: 3,221 files before and after; no additions or removals; input hashes equal.
- Owned process group: PGID `1977335` exited `1` and was absent; no TERM, KILL, timeout, signal, or forced cleanup hold.
- Forbidden request-stream diagnostic count: `0`; retained stderr otherwise contains the Node deprecation, sourcemap warnings, and the isolated-storage failure receipt.

The corrected fixture is reserved for a separate continuation packet. No rerun or
isolation-strategy change is represented here. The complete selected raw output
file list and SHA-256 values are in
[`output-manifest-1.json`](output-manifest-1.json); raw files remain under
`tmp/provider-restore-allocation-1` and are not copied or mutated.
