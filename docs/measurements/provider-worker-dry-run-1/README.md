# Worker-only production dry-run

This packet freezes a local Wrangler bundle check for the production worker
source at `4a22c1d65549577e42a12d390949d95e408eed2a`. It archives the worker
and its local container build context from that commit, then invokes the
installed Wrangler `4.125.0` CLI directly through Node with:

```text
deploy --dry-run --outdir <output>/bundle --metafile <output>/metafile.json --containers-rollout=none
```

`--dry-run` prevents an upload. `--containers-rollout=none` is the installed
Wrangler path that skips local Docker verification/build and the container
deployment callback. The configured container, Durable Object bindings,
migrations, and production `REALM_REGISTRY` namespace remain in the generated
metadata. This packet does not read credentials, contact Cloudflare, or invoke
a deployment.

The production `worker/wrangler.jsonc` bytes are pinned to the source commit
and independently equal the recorded `76f9028` production config. The runner
captures exact bundle and metafile SHA-256 maps, the production config identity,
the archived source, the installed Node/Wrangler binaries, and the installed
worker runtime membership. It uses a fresh private output and owned process
group with signal latching and bounded cleanup. The dry-run child is bounded
at 90 seconds; the outer packet envelope is 150 seconds, with TERM after five
seconds and KILL after a further two seconds. Root may reserve an additional
30 seconds outside that envelope for receipt cleanup.

Root owns any future execution. From this worktree, use one fresh output path:

```sh
docs/measurements/provider-worker-dry-run-1/run_provider_worker_dry_run.py \
  /tmp/provider-worker-dry-run-1
```
