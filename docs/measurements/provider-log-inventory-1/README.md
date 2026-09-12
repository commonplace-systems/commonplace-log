# Provider log inventory stage

This stage adds one provider internal wire operation, `POST /list-logs`, to the
existing `storageFetch` seam. It is never dispatched by the public realm
handler. The operation returns the complete bounded catalog of provider logs,
including logs created by normal storage and logs landed by bundle restore. It
does not inspect or return the realm secret, secret hash, or realm metadata.

The catalog is limited to 64 logs, 4096 writer tips, and a 256 KiB UTF-8
response/catalog budget. IDs and metadata strings are bounded to 256 UTF-8
bytes. SQLite count, length, and state checks run before variable-width fields
are selected. The generation is a deterministic SHA-256 digest over framed
sorted catalog fields; callers can take two observations and require equality
when they need a conservative unchanged check. It is not an atomic snapshot
across independent log databases.

The focused worker test has four cases: mixed normal/restore inventory with
public-route closure and generation changes after create and commit; empty
provisioned storage without schema creation; count/UTF-8 metadata/malformed
metadata bounds; and pending/orphan state refusal. The expected native result
is four defined, four passed, zero failed, and zero pending tests.

Run from this worktree after committing the source:

```text
python3 docs/measurements/provider-log-inventory-1/run_provider_log_inventory.py /absolute/fresh/output
```

The runner archives the clean current commit into the fresh output, binds the
pinned cached worker dependencies from `/home/jes/commonplace-log/worker/node_modules`,
and invokes only `worker/test/realm/log-inventory.workers.test.ts`. It records
the exact argv, source and dependency SHA-256 maps before and after, including
post-run dependency membership discovery, stdout, stderr, native/verdict
status, and owned process-group cleanup. It uses a
120-second child bound followed by TERM for five seconds and KILL for two
seconds. No dependency install, cloud endpoint, deployment, account
activation, or public provider route is part of this stage.
