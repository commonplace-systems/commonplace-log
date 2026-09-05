# Backup Worker

`wrangler.backup.jsonc` is a second Worker, with no Containers configuration,
HTTP handler, or active cron. It binds the existing `commonplace-log` script's
`RealmNode` namespace, the existing realm-registry KV namespace, and the backup
R2 bucket. Set the real registry namespace ID before any separately authorized
activation; the checked-in placeholder is not a working deployment configuration.
This round neither deploys nor changes a live binding or bucket.

`scheduled()` runs the registry walk and rejects if its persisted run reports a
stop. Only the local test entry exports `POST /run`. The production module exposes
no HTTP trigger. Tests use local Workers SQLite, KV, and R2; no Cloudflare account
credentials are needed.

The source contract is based on log main `b75ac47` plus the `/list-logs` addition
in this round. Before activation, compare the deployed `prov:source-sha` to the
landed implementation containing that route; the pre-round deployed script cannot
serve it. That deployment comparison is an activation prerequisite, not a check
this code-and-tests round has performed.

Run checks from `worker/`:

```sh
npm ci
npx vitest run --config vitest.backup.config.ts --reporter=verbose --sequence.seed=20260905
npx tsc -p tsconfig.backup.json --noEmit
bash scripts/check-backup-boundary.sh
npm test
```

The normal test command includes the backup project. The focused TypeScript check
does not include unrelated legacy test files; the existing full check still
reports the two previously documented TS2307 errors in the read-capability tests.

See [design correction §9](../../docs/backup-design.md#9-correction-enumerate-logs-preserve-log-identity-and-use-writer-cursors)
for the layout. `frontier.json` contains `{version: 1, log_id, writers}` where
each writer has `writer_id`, `seq`, `entry_id`. `manifest.json` contains
`{version: 1, realm_id, log_ids}`. Checkpoints contain no credentials. Entries retain
source bytes; objects at an existing coordinate are compared, never replaced.

Conditional R2 writes use `etagDoesNotMatch: "*"` for new objects and `etagMatches`
for checkpoint replacement. A failed condition returns `null`; it is treated as
a conflict rather than successful advancement. See the
[Cloudflare R2 API reference](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/).

Each `_runs/<uuid>.json` records start/end timestamps, the exact number of registry
keys visited, per-realm appended counts, frontier/manifest writes, and named stops.
It reports coverage as `registered_realms_only`, including when the registry is
empty. It cannot prove that production's registry is complete. A realm stop does
not suppress the other registered realms. A run-log write failure rejects the
invocation; no system can persist its failure into the same unavailable bucket.

Failure names include `capability_rejected`, `realm_not_found`, `read_failed`,
`read_refused`, `invalid_response`, `source_regressed`, `writer_fork`,
`backup_entry_conflict`, `checkpoint_conflict`, `storage_failed`, and registry
failures. No remote error body or exception message is copied into the log.

The registry interface exposes only `get` and `list`, and the client accepts only
the three read routes it needs. Cloudflare's KV binding itself is not attenuated
by that TypeScript interface; the source check establishes what this Worker calls,
not a platform sandbox for arbitrary replacement Worker code.

An invocation snapshots each log frontier independently. This is not a cross-log
transaction or a point-in-time realm snapshot. Newly created logs can appear in
a later run. Overlapping runs may stop with a checkpoint conflict and retry later.
There is no retention/deletion, registry repair, or restore implementation here.
