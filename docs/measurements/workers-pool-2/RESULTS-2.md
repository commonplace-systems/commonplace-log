# Workers-pool focused measurement — run 2

This retained follow-up selected the 23 assertion names left incomplete by run 1. The native Vitest child completed successfully, but the wrapper rejected the run because it retained ten stream diagnostics; no wrapper acceptance or overall green result is claimed.

- Source: `4a22c1d65549577e42a12d390949d95e408eed2a`
- Fixture: `cc8afaac0f84fde21a621e37300cf0cb755d47ca`
- Selected assertions: **23 passed, 20 skipped** from the 43-name full set
- Native child exit: `0`; wrapper verdict exit: `125`
- Wrapper reason: `unexpected stream diagnostics` only

The retained output records ten stream diagnostics in `tmp/workers-pool-2/stderr`. This result records their count and leaves their origin unattributed; it does not infer a product or fixture cause.

Integrity and cleanup checks passed: input count `3277` was pre/post equal; the runtime inventory stayed at `3221` with no additions or removals; process group `2075844` was absent after cleanup, with no TERM, KILL, timeout, or first-signal event.

Together, the retained run 1 and run 2 assertion manifests pass all 43 assertion names at least once. Neither wrapper accepted the combined evidence: run 1 stopped on its undefined-helper failure, and run 2 was rejected for stream diagnostics. The original run-2 output remains under `tmp/workers-pool-2/`; its retained top-level SHA manifest is `tmp/workers-pool-2/original-output-sha256.json`.
