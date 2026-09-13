# Deployment realm allocation runner

This packet runs the frozen seven-case Vitest suite for the deployment-owned
realm allocation route. The suite uses actual `SELF` ingress and the real
`REALM_CONTAINER` SQLite storage. It covers idempotent replay, conflicting
operation and secret refusal, legacy-created realm refusal, deployment and
realm bearer authorization, internal-path/spoof-marker refusal, plaintext
secret exclusion, and malformed secret rejection.

The provider source is based on accepted source `a15a9f4cdbab111db2a1c7fb979203b23732113b`
and the reviewed allocation implementation is pinned at `5f9e810`. The frozen
fixture is commit `cb490e6` at
`worker/test/realm/allocate.workers.test.ts`. The runner allows only the three
reviewed allocation source files, that fixture, and these two packet files in
the post-source tree; unrelated product or fixture changes fail the guard.

Run from a fresh output path after the source, fixture, and packet are committed:

```text
python3 docs/measurements/provider-restore-allocation-1/run_provider_restore_allocation.py /absolute/fresh/provider-restore-allocation-1
```

The child uses the pinned local worker runtime, the container-free
`wrangler.test.jsonc` binding, and the synthetic Vitest gateway token. It does
not call `storageFetch`, install dependencies, contact a cloud endpoint, or
replay another suite. Root and worker Vitest configs use separate absolute
`cacheDir` values under the fresh output. The runner records full SHA-256 maps
for the runtime before and after, the executed source and generated configs,
exact JSON test results, stderr, and owned process-group cleanup.
