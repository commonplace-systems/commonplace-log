# Workers-pool continuation measurement packet

This root-owned continuation selects the exact 23 non-passing assertions from
`tmp/workers-pool-1`: the one failed allocation case and its 22 pending
assertions. It runs all six focused files with Vitest `--testNamePattern`, then
requires all 43 assertion records to be present, the selected 23 to be passed,
and the retained 20 original passes to remain pending or skipped. The 20
original passes are not replayed as selected work.

The corrected provider source is pinned to
`4a22c1d65549577e42a12d390949d95e408eed2a`. The fixture remains pinned to
`cc8afaac0f84fde21a621e37300cf0cb755d47ca`, with SHA-256
`d0a499d49e78f109f4e5af224537405d86a4f23aec081e5a204f92cd5f9a1bc0`.
The retained run-1 output is bound by hashes for its result, verdict, native,
process-group, PRE/POST input, equality, runtime, source-pin, command, stdout,
and stderr records.

The runner uses `/usr/bin/node` and the installed Vitest module directly, with
no install or `npx`. It pins all 3,221 runtime files before and after execution,
uses fresh root and worker cache directories, checks both `REALM_CONTAINER` and
`REALM_REGISTRY`, and gates stream diagnostics, signals, status, input equality,
runtime membership, and process-group cleanup. The child budget is 150 seconds
with TERM after 5 seconds and KILL after a further 2 seconds; the intended
external envelope is 210 seconds plus 30 seconds cleanup.

From the provider worktree, use a fresh output directory:

```sh
docs/measurements/workers-pool-2/run_workers_pool_continue.py tmp/workers-pool-2
```

No native execution is included in this commit.
