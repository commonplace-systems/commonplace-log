# Deployment allocation continuation results

The retained continuation reached a native pass for the five unconsumed
allocation assertions. Root session `73774` returned final
receipt `8f52da`; native rc was `0`, but the outer packet
verdict was `125` because the wrapper observed two forbidden
request-stream diagnostics.

- Defined assertions: 7; selected: 5; selected passed: 5; failed: 0.
- The two prior green assertions were filtered and appear only as skipped records; they were not replayed.
- Source archive HEAD: `0297977f0a08bb47de6236c2be144ab01560c404`; corrected fixture `505821c74e3a7696a3ef4706bd73135a3982f93c` with SHA-256 `7f56a42e86394bb704e36c634ace00a02c631662fb6b212fea4adf3f82277bd1`.
- Runtime membership: 3,221 files before and after; no additions or removals; input hashes equal.
- Owned process group: PGID `1983784` exited `0` and was absent; no TERM, KILL, timeout, signal, or forced cleanup hold.
- Wrapper diagnostic count: `2`. Both are retained workerd request-stream messages. The output has no URL-to-request association, so this evidence does not assign either message to an individual test or claim a source cause.

The complete selected raw output file list and SHA-256 values are in
[`output-manifest-2.json`](output-manifest-2.json). Raw files remain under
`tmp/provider-restore-allocation-2` and are not copied or mutated. Scope is the
five-case continuation only; no cloud, deployment, account activation,
credential, or production-route claim is made.
