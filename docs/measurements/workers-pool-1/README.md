# Workers-pool focused measurement packet

This packet is a static, root-owned native runner for the deployed-base worker
suite. It selects the 37 preserved declarations from `read_capability`,
`registry`, `realm_remove`, `delete_all`, and `ingress`, plus the six focused
cases in `worker/test/realm/allocation_registry.workers.test.ts`: 43 selected
cases in total. The runner checks the selected Vitest full-name manifest, so an
unselected or newly passing declaration cannot silently expand the result.

The provider source is pinned to commit
`474cf369c175dc7f9685cbb22f901d25278879ce`. The focused fixture is loaded from
commit `cc8afaac0f84fde21a621e37300cf0cb755d47ca`, path
`worker/test/realm/allocation_registry.workers.test.ts`, with SHA-256
`d0a499d49e78f109f4e5af224537405d86a4f23aec081e5a204f92cd5f9a1bc0`.
The generated Wrangler configuration is required to retain both the
`REALM_CONTAINER` Durable Object binding and the `REALM_REGISTRY` KV binding.

The runner uses the installed `/usr/bin/node` and
`/home/jes/commonplace-log/worker/node_modules/vitest/vitest.mjs` directly;
it does not install packages or use `npx`. The pinned runtime tree contains
3,221 regular files. It is hashed before and after the child, as are the
materialized source, fixture, generated config, runner, Node executable, and
Vitest executable. Runtime additions or removals, any input hash change, a
stream diagnostic, an unexpected signal, a nonzero child status, an incomplete
full-name result, or unproven process-group cleanup makes the verdict fail.
The generated Vitest config uses a fresh worker cache directory inside the
output namespace.

The child budget is 150 seconds with TERM after 5 seconds and KILL after a
further 2 seconds. The intended external envelope is 210 seconds plus a
30-second cleanup allowance. The runner owns one process group and records its
native exit and cleanup state. No native execution is part of this commit.

From the provider worktree, the root-owned command is:

```sh
docs/measurements/workers-pool-1/run_workers_pool.py /tmp/workers-pool-1
```

The output directory must be fresh. The script materializes its own context,
cache, HOME, and TMPDIR beneath that output and writes the PRE/POST manifests,
selected Vitest result, runtime membership, process-group record, native record,
and verdict there.
