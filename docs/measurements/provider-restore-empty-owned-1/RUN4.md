# Empty-owned restore fresh run four

Run four repeats all six fixture cases after the three prior native runs
failed during isolated storage teardown. It recursively audits each prior
output tree before archiving or launching the worker, preserving their raw
artifacts and supplemental root completion records.

The generated Vitest worker config changes only
`test.poolOptions.workers.isolatedStorage` to `false`; it spreads the base
worker pool, Wrangler, Miniflare, test, and cache options through unchanged
and uses a private fresh cache directory. Each fixture case already chooses a
unique Durable Object name; this packet makes no snapshot-isolation claim.

The verdict requires six actual JSON assertion records in `test-result.json`,
all with status `passed`, matching the six frozen titles. A summary success
flag with pending assertions cannot pass the runner.

Run with a fresh output directory:

```sh
python3 docs/measurements/provider-restore-empty-owned-1/run_provider_restore_empty_owned_four.py \
  /home/jes/commonplace-log-restore-empty-owned/tmp/provider-restore-empty-owned-4
```

Bounds remain 120 seconds for the worker, TERM five seconds, and KILL two
seconds. Root owns native execution.
