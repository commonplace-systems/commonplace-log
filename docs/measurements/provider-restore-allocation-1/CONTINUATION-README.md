# Deployment realm allocation continuation runner

This is a separate continuation of the retained `provider-restore-allocation-1`
run. It executes only the five allocation assertions that were unconsumed after
the original suite stopped: legacy-created realm refusal, bearer authorization,
internal allocation/spoof-marker refusal, plaintext-secret exclusion, and
malformed-secret rejection. The two assertions that already passed are excluded
by an exact Vitest test-name pattern and are not replayed.

The continuation pins reviewed allocation source
`5f9e810665ba3a52085dcde9b02e53ddbc180fa5` and corrected fixture
`505821c74e3a7696a3ef4706bd73135a3982f93c`. It permits the reviewed allocation
source files, frozen fixture, existing initial packet/evidence files, and this
continuation runner/README only. Product or fixture drift fails the provenance
guard.

Run from a fresh output path under the root-owned continuation envelope (240
seconds outer time with 30 seconds cleanup grace; the child native budget is
180 seconds):

```text
python3 docs/measurements/provider-restore-allocation-1/run_provider_restore_allocation_continue.py /absolute/fresh/provider-restore-allocation-continue-1
```

The child uses the pinned local worker runtime, separate absolute root and
worker Vitest `cacheDir` values under the fresh output, the container-free
`wrangler.test.jsonc` binding, and the synthetic gateway token. It uses actual
`SELF` ingress and `REALM_CONTAINER` SQLite storage, does not call
`storageFetch`, install dependencies, contact a cloud endpoint, or replay the
two prior green assertions. It records full runtime SHA-256 maps, exact JSON
results, stderr, and owned process-group cleanup.
