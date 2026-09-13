# Empty-owned restore targeted run five

Run five targets only the exact first fixture title after the ingress-order
correction:

`creates a complete catalog marker for a configured non-null writer with no entries`

It audits all four prior output trees recursively before starting. The
expected Vitest envelope is six defined, one passed, five pending/skipped,
and zero failed; the verdict additionally requires six assertion records in
frozen order, the first `passed`, and all remaining records explicitly
`pending` or `skipped`. This retains the five green cases from run four as
historical evidence and does not replay them.

The generated worker config changes only
`test.poolOptions.workers.isolatedStorage` to `false`, preserving the base
nested options and private cache. Bounds remain 120 seconds for the worker,
TERM five seconds, and KILL two seconds.

Run with a fresh output directory:

```sh
python3 docs/measurements/provider-restore-empty-owned-1/run_provider_restore_empty_owned_five.py \
  /home/jes/commonplace-log-restore-empty-owned/tmp/provider-restore-empty-owned-5
```

Root owns native execution. Prior raw outputs remain unchanged.
