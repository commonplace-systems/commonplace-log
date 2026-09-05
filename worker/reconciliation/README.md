# Registry reconciliation library

This is administrative code, separate from the pinned read-only backup Worker.
It has no deployed entry, HTTP route, cron, credential lookup or Cloudflare account
client. Existing backup source and its review manifest are unchanged.

`reconcile(env, {countStoredObjects})` defaults to dry run and returns a sensitive
in-memory report. It writes nothing. The caller supplies an independent stored-DO
count observation with its instrument name; the library lists registry keys for
the other count. Missing/failed counts stay null, not zero. The signed difference
is diagnostic, not proof of completeness: equal counts can hide offsetting holes.

A row is `absent` only after HTTP 404 with the expected `ok:false` / `not_found`
body from its DO. A validated successful read is `present`. Transport failure,
timeout, 5xx, malformed/unexpected response, rejected capability or failed registry
read is `unknown`, with a named cause. Unknown rows are never deleted. Complete
registry enumeration precedes all deletion; a failed page preserves every row.

Deletion requires BOTH `apply:true` and `lifecycleQuiesced:true`. The latter is an
explicit acknowledgment of an externally enforced lifecycle maintenance window,
not an internally acquired lock. Do not assert it while create/removal can race.
Each absent row is read again byte-for-byte before deletion. A failed, missing or
changed recheck is unknown and preserves the row. KV provides no atomic
compare-and-delete; a byte recheck does not protect the interval after that read
and eventual consistency further limits its value. Arbitrary concurrent recreation
is not safe. The planner ranked `REGISTRY-SELF-DELETE-1` to move deletion into the
DO's lifecycle gate under a separately authorized administrative route.

The report names every examined row, its verdict/cause and action. A delete error
is recorded as `delete_failed`; it is not counted as a success. Reports contain no
capabilities or raw exception bodies, but realm identifiers remain sensitive.
Keep them within the approved backup custody boundary. There is no CLI that prints
a live report and no production invocation/persistence wiring in this round.

The independent count callback must be implemented by the eventual authorized
operator adapter (all pages of the correct DO namespace's objects listing,
counting `hasStoredData`). Local tests instead enumerate local DO IDs and inspect
user-table storage independently of KV. Those are fixture counts, not production
measurements. No live account call is necessary to run the tests.

An unregistered live realm has no name in the registry. The DO object listing
cannot reverse idFromName to recover it. Backfill must begin with realm IDs held
by their creator, commonplace-next, and requires its own capability-custody plan;
knowing an ID does not recover a lost read capability. Reconciliation does not
mint secrets, infer names from counts, or repair that direction.
