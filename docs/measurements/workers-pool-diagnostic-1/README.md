# Workers-pool request-stream diagnostic packet

This packet contains two sequential, isolated observation arms for the
request-stream diagnostics seen in the focused continuation. The baseline arm
loads source `76f9028112feeba557e4d45060f1cbdead98e7f3` and runs only
`realm ingress requires the deployment token for create`. The candidate arm
loads source `4a22c1d65549577e42a12d390949d95e408eed2a` and runs only
`deployed-base allocation and registry requires the deployment bearer and
never treats a read capability as allocation authority`.

Each arm has a fresh materialized context, root cache, worker cache, HOME,
TMPDIR, and process-group record. Both use the installed Node/Vitest runtime
directly, pin all 3,221 runtime files before and after execution, preserve the
exact one-case result, and retain complete stdout/stderr diagnostics. The
fixture source remains pinned to commit `cc8afaac0f84fde21a621e37300cf0cb755d47ca`
with SHA-256
`d0a499d49e78f109f4e5af224537405d86a4f23aec081e5a204f92cd5f9a1bc0`.

The result records the request-stream diagnostics for each probe. A diagnostic
is retained as an observation and does not become an automatic variant or a
claim that the full ten-line historical set has been localized. Existing
deployed-base diagnostic logs remain separate evidence.

The child budget is 60 seconds per arm with TERM after 5 seconds and KILL
after a further 2 seconds. The intended external envelope is 210 seconds plus
30 seconds cleanup. Root owns native execution; this commit performs no run.

From the provider worktree, use a fresh output directory:

```sh
docs/measurements/workers-pool-diagnostic-1/run_workers_pool_diagnostic.py tmp/workers-pool-diagnostic-1
```
