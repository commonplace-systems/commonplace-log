# Provider restore empty-owned log

This packet archives the clean current worker source and runs six focused
Vitest Durable Object cases from
`worker/test/realm/restore-empty-owned.workers.test.ts`. It uses the pinned
`/home/jes/commonplace-log/worker/node_modules` tree, a fresh archived source,
private HOME/XDG/TMP roots, local SQLite-backed Durable Objects, and Vitest
project `do`. The runner gives Vitest a private cache directory and does not
install dependencies or contact a hosted provider.

The frozen cases are:

1. `creates a complete catalog marker for a configured non-null writer with no entries`
2. `fences normal APIs during a mixed empty and non-empty pending bundle, then completes`
3. `replays an empty owned bundle idempotently without changing SQLite state`
4. `takes a lease and commits after empty restore, then replay preserves the tip and lease`
5. `refuses an existing unmarked empty target and writer, archive, or bundle rebinding`
6. `fails closed for zero-byte entries and inconsistent restore count metadata`

The runner requires ancestry from provider commit
`5c7e3fe3ff5a33ce9fd0b4f4d1aa5e28216bcb4c`, archives the exact clean HEAD,
binds worker source/config/package/fixture files and the complete pinned
runtime tree before and after execution, and retains runtime membership
additions/removals. The worker child is bounded at 120 seconds with TERM
five-second grace and KILL two-second grace. Native and cleanup records are
retained even when a signal interrupts the run.

Run with a fresh output directory:

```sh
python3 docs/measurements/provider-restore-empty-owned-1/run_provider_restore_empty_owned.py \
  /home/jes/commonplace-log-restore-empty-owned/tmp/provider-restore-empty-owned-1
```

Root owns native execution.
