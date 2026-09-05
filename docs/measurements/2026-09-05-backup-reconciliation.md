# BACKUP-1b-iii: registry reconciliation without deleting on an unknown read

Base after fetch: `330c013cfa43b44c0e2fbfa6ef6e967ce20a1195`, including
BACKUP-KEYS-1. Branch `work/backup-reconciliation-2026-09-05`.

## Outcome and scope

A new administrative library in `worker/reconciliation` returns a per-row report
and defaults to dry run. It deletes only after an explicit not_found DO reply,
explicit apply and lifecycle-quiescence acknowledgment, and a successful unchanged
registry-byte recheck. Transport failure, timeout, 5xx, malformed/unexpected reply,
rejected capability, registry read failure or changed/failed recheck stays unknown
and never deletes. The report contains causes, actions, counts and removals; it
contains no read capabilities or raw exception messages.

**333 tests passed across 26 files**, seed **20260905**. Focused typecheck and the
existing backup boundary pass. Full typecheck returns 2 with exactly the inherited
TS2307 diagnostics at read_capability.workers.test.ts:157/158.

This is a callable library with no deployed entry, HTTP route, cron, CLI that
prints reports, Cloudflare account client or production count adapter. No live
account read, write, deletion or deployment occurred. The existing backup source,
its pinned hashes, READ_ROUTES, create/removal paths and capability minting are
unchanged. One new test file is discovered by the existing backup test project;
no existing assertion or configuration was edited. Its imports also place the
new module under the existing focused typecheck without configuration changes.

## Restated premise and §0 measurements

Read `realm_auth.ts`'s explicit not_found return and the removal branch that wipes
DO storage before unregistering; an unsuccessful unregister can leave an orphan.
Read `realm/registry.ts`'s one-way name/object-ID limitation. These premises remain
true at this base. The backup still enumerates only registered realms, so an
unregistered live realm remains outside both its inventory and its own coverage
checks.

§0 uses fixtures, not the live account. The instruments are independently derived:

| Stage | KV list/read instrument | Local DO enumeration + user-table storage inspection |
| --- | --- | --- |
| Orphan arm, before reconciliation | 2 rows with their original bytes | 1 object with user storage |
| Missing-registration control | 2 rows | 2 objects with user storage |
| Same control after deleting one fixture registry row | 1 row | 2 objects with user storage |

Local tests use the real RealmContainer SQLite implementation and Workers KV.
The orphan is created by creating a realm and wiping its DO storage directly while
retaining the KV row, simulating the durable state after unregister fails. Neither
count is computed from the other. The count callback enumerates local DO IDs and
inspects their user tables; it does not use KV names to select objects. These are
local observations, not a measurement of the deployed RealmNode namespace.

An eventual operator adapter must supply the independent platform count by paging
the correct DO namespace's objects listing and counting hasStoredData. That live
read belongs to boss's window and was not requested for this local round. Failed
counts remain null with a cause, and a partial registry enumeration is explicitly
unknown and cannot produce a deletion plan. Equal counts do not prove completeness:
an orphan and an unregistered live realm can cancel numerically.

## Arms, controls and evidence

[Checksummed raw evidence](2026-09-05-backup-reconciliation/) includes complete
logs, direct process statuses, source/test hashes and implementation diff.

| Arm | Measured control and result |
| --- | --- |
| R1 | Fixture registry starts at 2 / stored DO 1. The orphan answers explicit not_found; dryrun would-delete count 1. Apply deletes that row only and retains the live row's original bytes. |
| R2 | Every failure fixture first reads its live realm as present. Separate transport, timeout and 503 injections yield unknown with distinct causes and retain byte-identical rows. Malformed 404, wrong 404 error and 401 also preserve rows. |
| R2 recheck | A failed recheck and a changed recheck each become unknown with named causes, call delete zero times, and preserve the stored row. |
| R3 | Default dryrun over the known orphan preserves the complete registry byte snapshot. Apply without quiescence acknowledgment rejects and also preserves it. Explicit apply changes the snapshot by exactly the orphan row. |
| R4 | A second apply removes zero, would-remove zero, and sees one remaining row. |
| R5 | Independent 2/2 control becomes 1/2 after deleting only one KV row; report delta is -1. A failed DO counter is null, with null delta and named cause, never zero. |
| R6 | Existing backup boundary rc 0 with production source hashes unchanged. No pre-existing test file or assertion changed. |

The load-bearing negative control changes only the probe's transport-error verdict
from unknown to absent. On the same live fixture, the log prints action `deleted`
and `row_retained: false`; the registry snapshot assertion fails, rc 1. This is an
actual fixture deletion, not merely an expected exception or a changed verdict.
The mutation source was restored byte-for-byte; the test remained unchanged.
The full 333-test suite then passed on restored source. The wrong variant's raw
output contains fixture identifiers/capabilities from the failed snapshot diff;
none are production data.

Commands ran from worker: focused backup project, filtered `R2: transport_error`
with the mutation, complete Vitest suite with seed 20260905, focused tsc, full npm
typecheck, and `scripts/check-backup-boundary.sh`. The focused run passed 22 tests
before the mutation; the final full run covers the same assertions after restore.

## Pre-edit race finding and remaining boundary

Flagged before implementation in message 29942: KV offers no compare-and-delete.
A DO's absent reply followed by an external delete can race recreation. A byte
recheck narrows the window but cannot close it, and eventually consistent KV reads
can be stale. The library requires `apply:true` AND `lifecycleQuiesced:true`; the
second is an operator acknowledgment, not a lock this library implements.
Arbitrary concurrent-recreation safety is explicitly not established.

Planner ruling 29945 approved the sibling module and this bounded operating
constraint. The sibling placement keeps administrative KV delete authority out
of the read-only backup and leaves its existing output gate intact. The ruling
also ranks **REGISTRY-SELF-DELETE-1**: move cleanup inside the DO's lifecycle input
gate, with an independently reviewed administrative authority path. That is the
mechanism that can close the race; a documented window is not its substitute.

A failed delete is reported as delete_failed and not counted as acknowledged
removal; no claim is made that a failed distributed call proves no side effect.
Reports are sensitive in-memory values for a future protected operator adapter,
not public debug output. Production invocation and protected persistence remain
unwired.

The inverse repair cannot be derived from counts: commonplace-next is the source
of realm names it created and must own a separate backfill round. Knowing the name
does not recover a lost existing read capability; minting one again is not an
automatic repair. This round neither backfills nor changes secret custody.
