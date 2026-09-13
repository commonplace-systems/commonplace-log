# Deployment realm allocation reserved-path continuation

This packet runs exactly one remaining allocation assertion: the internal
`/realm/allocate` path and spoof-marker refusal control. The other six
allocation assertions, including the two prior green cases and the four cases
that passed in the five-case continuation, are excluded by an exact Vitest
name pattern and are not replayed.

The packet pins the reviewed gateway correction at
`cf99058`, source base `a15a9f4cdbab111db2a1c7fb979203b23732113b`, and frozen
fixture `505821c74e3a7696a3ef4706bd73135a3982f93c`. The provenance guard allows
the three allocation source files, the frozen fixture, the existing allocation
packet/evidence files, and this README/runner pair only.

Run from a fresh output path under the root-owned native envelope:

```text
python3 docs/measurements/provider-restore-allocation-1/run_provider_restore_allocation_spoof.py /absolute/fresh/provider-restore-allocation-spoof-1
```

The child uses the pinned local worker runtime, separate absolute root and
worker Vitest `cacheDir` values, the container-free `wrangler.test.jsonc`
binding, and the synthetic gateway token. It uses actual `SELF` ingress and
`REALM_CONTAINER` SQLite storage, does not call `storageFetch`, install
dependencies, contact a cloud endpoint, or replay another case. The native
acceptance gate requires one selected pass, six excluded pending/skipped
records, unchanged runtime hashes, clean owned-process teardown, and zero
request-stream diagnostics.
