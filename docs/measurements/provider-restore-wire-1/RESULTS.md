# Provider restore wire results

These are the three retained native runs for the internal provider restore bundle wire. The fixtures use synthetic local Durable Objects. The outbound identity result covers target mapping through the test shim; it does not establish behavior of a real cloud RPC boundary. The original failing runs remain recorded as failures.

## provider-restore-wire-1

- Session `16472`; source `6194033da72b6645a540eb82fb6961e2cf568997`.
- Command: `env RESTORE_WIRE_OUTPUT=/home/jes/commonplace-log-restore-wire/tmp/provider-restore-wire-1 bash worker/run-restore-wire.sh`.
- Native/verdict rc `1/1`; existing HTTP/ingress `28` tests and unit outbound `3` tests passed. The new wire file reported two failures, three uncompleted cases, and one unhandled error.
- The retained failure includes isolated-storage teardown observing `.sqlite-shm` after the first public authorization case and request-stream diagnostics. This run is incomplete and is not relabeled by later runs.
- The 28 pre/post input hashes are equal and the temporary dependency symlink was removed.

## provider-restore-wire-2

- Session `78264`; source `bd29626d853d9fbb869169cf86b7827165847e3c`.
- Command: `env RESTORE_WIRE_CONTINUE_OUTPUT=/home/jes/commonplace-log-restore-wire/tmp/provider-restore-wire-2 bash worker/run-restore-wire-continue.sh`.
- Native/verdict rc `1/1`; all five wire cases ran, with three passing and two failing.
- The retained failures were post-abort reuse of the original stub and a Request crossing into a different Durable Object callback in the outbound test shim.
- The 25 pre/post input hashes are equal and the temporary dependency symlink was removed.

## provider-restore-wire-3

- Session `35192`; source `a7bbaf1ab38ab95e1029d08e3d571ad7f4de06b7`.
- Command: `env RESTORE_WIRE_CONTINUE_2_OUTPUT=/home/jes/commonplace-log-restore-wire/tmp/provider-restore-wire-3 bash worker/run-restore-wire-continue-2.sh`.
- Native/verdict rc `0/125`; the exact two continuation cases passed and the other three cases were skipped (`2 passed | 3 skipped (5)`).
- The wrapper verdict was `125` because its retained parser required one space after `Tests`, while Vitest emitted two. The native result and independent retained report establish the two-pass/three-skip selection; this parser mismatch does not change the native rc.
- The 25 pre/post input hashes are equal and the temporary dependency symlink was removed.

Across the retained native coverage, `31` earlier green checks, `3` wire checks in run 2, and `2` wire checks in run 3 are accepted (`36` passes). The original run 1 and run 2 failures remain represented as failures. No product-cause claim is made from the earlier fixture hypotheses beyond the observed retained errors and the test-shim scope.

Raw artifact SHA-256 values are recorded in [`RESULTS.json`](./RESULTS.json). The three `pre.sha256` and `post.sha256` artifacts are equal within each run, binding each recorded source revision and runner input set to its output.

## Scope and limits

- Pinned dependencies: `/home/jes/commonplace-log/worker/node_modules`.
- Outer timeout: 270 seconds; termination grace: 5 seconds.
- Coverage is local synthetic Durable Object wire behavior and test-shim target selection.
- The runs make no claim about real cloud RPC stream transport, provider authentication, cloud deployment, provisioning, application activation, or public grants.
