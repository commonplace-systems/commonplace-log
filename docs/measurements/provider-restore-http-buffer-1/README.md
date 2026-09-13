# Public ingress buffering runner

This packet runs one Vitest worker case against the bounded ingress buffering
source. The selected case sends a body-bearing wrong-secret request, confirms
the correct-secret inventory and restore paths, and sends a `32 MiB + 1` body
that must return `413` without changing the Durable Object rows.

The worker source is pinned at or below the accepted buffering commits
`f5f860c8ae2b47da39fb08018d29834ba70500b4` and
`a15a9f4cdbab111db2a1c7fb979203b23732113b`; the fixture is
`0c303e24a60a8dfae4368c2e6c9fe436fe984034`, cherry-picked from the reviewed
fixture commit `fbe5056e2b84f4bda3c10b4e2f03f33aca09a8eb`. The runner archives
the actual clean HEAD and verifies that the only post-`a15a9f4` changes are this
fixture and the two packet files.

Run from a fresh output path after the fixture and source are committed:

```text
python3 docs/measurements/provider-restore-http-buffer-1/run_provider_restore_http_buffer.py /absolute/fresh/provider-restore-http-buffer-1
```

The child uses the pinned local worker runtime, the container-free
`wrangler.test.jsonc` binding, and the synthetic Vitest gateway token. It does
not call `storageFetch`, install dependencies, contact a cloud endpoint, or
replay the earlier broad public fixture. The runner creates separate root and
worker Vitest configs with explicit absolute `cacheDir` values under the fresh
output. It records full SHA-256 maps for every runtime file before and after,
the executed source and generated configs, exact JSON test results, stderr, and
owned process-group cleanup.
