# Repository review and proposed next work

Reviewed 2026-09-05 at `778997e`, branch
`wip/store-1a-sqlite-server-adapter-2026-09-03`. This is a review of the local
checkout, not a claim about current production or the latest remote main.

After the review, `git fetch origin` resolved main to `60715aa`. The intervening
commits add read capabilities, backup registry work, and a round launcher. A diff
confirmed the cited CI, README, SQLiteServer implementation/tests, Sync, and
Amendment 2 are unchanged there. Those additional auth/registry/launcher paths
were not audited; the test results below still apply specifically to `778997e`.

## Recommendation

Within this review's maintenance scope, first put the existing worker typecheck in CI. Next add focused write-path
coverage for the newly published `Persistence.SQLiteServer` adapter, coordinated
with commonplace-plan's STORE work. Then automate the existing local socket
integration test. These are bounded changes that strengthen existing guarantees.
The planner's broader queue prioritizes preserving existing realm-removal work
before these improvements; see the discussion outcome below.

The architecture already has valuable separation: Engine owns protocol decisions,
persistence owns atomic storage, and Document/Cell own semantic authority. Preserve
the independent implementations, fixed conformance corpus, failure controls, and
transactional epoch fencing. This review does not propose protocol redesign.

## Prioritized findings

### 1. Run the existing TypeScript check in CI — high confidence, small

Evidence: [worker/package.json](../../worker/package.json) defines `typecheck`
as checks of both TypeScript configurations, but
[ci.yml](../../.github/workflows/ci.yml) only invokes `npm test` for the worker.
There is no separate typecheck step. The existing command passed in this review.

Improvement: add `npm run typecheck` after dependency installation and update the
workflow's description of its checks. Include it in the README's local commands.

Acceptance: both configurations pass on the candidate tree; an intentional type
error in a temporary verification copy makes the command fail. This closes a
missing check; it is not evidence of an existing type error.

### 2. Exercise writes through SQLiteServer's public adapter — high confidence, small to medium

Evidence: [SQLiteServer](../../commonplace_log/lib/commonplace/log/persistence/sqlite_server.ex)
publishes all seven Persistence callbacks, including `commit/2`. Its
[dedicated tests](../../commonplace_log/test/persistence_sqlite_server_test.exs)
cover generic reads and six log-mismatch paths, but never invoke the proxy's
`commit/2`. Seeding uses DocumentProfile's lane path, so those writes do not
establish that the new proxy write path works. The
[STORE-1a record](../superpowers/plans/2026-09-03-store-1a-sqlite-server-persistence-adapter.md)
explicitly excludes this adapter from the full shared persistence contract because
an open server with an absent log is unreachable.

Improvement: retain that valid exclusion and add focused tests for reachable
write states: successful Engine merge through the proxy, wrong-log commit,
stale revision, obsolete epoch, and successful commit with current values.
Assert both the returned result and unchanged durable rows/tips on rejection.
Exercise successful lease advancement through the proxy as part of the setup.

Acceptance: tests observe the adapter's own callbacks, fail if its commit binding
or forwarding is broken, and demonstrate that rejected writes change no state.
Do not expose the server's raw connection or weaken the existing contract to fit
this adapter. This is a coverage gap, not a demonstrated corruption defect.

### 3. Run the existing local socket integration arm automatically — high confidence, medium

Evidence: CI explicitly says it does not run the arms in
[GATED_ARMS.txt](../../commonplace_log/test/GATED_ARMS.txt).
[wrangler_real_socket_integration_test.exs](../../commonplace_log/test/wrangler_real_socket_integration_test.exs)
already launches local Wrangler with temporary persistence. The
[inventory script](../../commonplace_log/scripts/check_gated_arms.sh) records a
previous regression that ordinary green suites missed. Inventorying the test
does not execute its transport path.

Improvement: add a bounded local integration job with
`RUN_WRANGLER_INTEGRATION=1 COMMONPLACE_LOG_WORKER_DIR=../worker`, running the
named file from `commonplace_log/`. Verify process cleanup and preserve logs on
failure. Verify its deliberate red arm separately before treating the new job
as evidence. Start with a manual CI trigger if runner reliability needs measurement.

Acceptance: the job actually executes the two named tests, fails on the intended
red control, and leaves no child Wrangler process. Keep deployed Container tests
separate: a local socket run does not establish production platform isolation.

### 4. Give readers a current documentation entry point — high confidence, small

Evidence: [README](../../README.md) says every entry has exactly eight fields,
but [Amendment 2](../protocol/0.1-amendment-2-entry-v2-operation-id.md) requires a
ninth `operation_id` field for v2, and
[DocumentProfile](../../commonplace_log/lib/commonplace/log/document_profile.ex)
already emits v2 prepared entries. Amendment 2's closing implementation note
still speaks of that emission as future work. The README's architecture table
also omits SQLiteServer, and its status/counts are explicitly dated August 25.

Improvement: distinguish v1 from v2 in the overview, link both amendments, explain
which append surface emits which version, and document a generic read using a
DocumentProfile handle's `adapter`, `store`, and `log_id`. Add a short current
status index to the readiness document so readers need not reconstruct the
latest state from superseded paragraphs.

Acceptance: examples match the reviewed implementation; historical measurements
retain their dates and hashes; current claims identify the check that supports
them. Preserve the original protocol text and historical decision records.

### 5. Define the sync deadline boundary precisely — investigation, small to medium

Evidence: [Sync](../../commonplace_log/lib/commonplace/log/sync.ex) checks an
absolute monotonic deadline between portions of work; adapter calls themselves
are synchronous and receive no deadline. `pull/4` enters snapshot frontier reads
before its per-writer expiry check. A slow adapter call can therefore outlast the
caller's requested deadline. The existing deadline test models partial progress,
not interruption of a blocked transport.

Improvement: document whether the option is a cooperative work budget or an
end-to-end timeout. Add deterministic tests for an already-expired pull and a
call that advances the injected clock past expiry. Only introduce transport
deadline propagation if a consumer needs a hard bound; that would require an
explicit adapter/API design decision.

Acceptance: documented semantics and tests agree, including empty frontiers and
slow calls. Do not promise cancellation or rollback of a write whose reply was
lost. No runtime defect was reproduced for this item during this review.

## Validation and limits

- `cd worker && npm run typecheck`: passed, both configurations.
- `cd commonplace_log && mix test test/persistence_sqlite_server_test.exs test/sqlite_server_test.exs test/sync_test.exs`:
  22 tests, zero failures; seed 597025.
- Inspected CI, protocol amendments, adapter/server implementation, sync,
  worker HTTP ingress, test configuration, and deployment-readiness records.
- Did not run the full suites, differential fuzzing, local socket arm, or deployed
  tests. No production requests or application code changes were made.
- `bd onboard` works, but `bd ready` reports no beads database in this checkout.
  Follow-ups are recorded here pending coordination with the existing planner;
  a second tracker was not initialized.

## Proposed sequence for commonplace-plan

1. Queue the CI typecheck and documentation corrections as a small maintenance task.
2. Coordinate the SQLiteServer write tests with STORE-1a/STORE-1b; verify which
   branch and consumer pin are authoritative before extending the work.
3. Queue local socket CI as a separate infrastructure task with explicit controls.
4. Resolve sync deadline semantics when prioritizing transport work.

## Discussion with commonplace-plan

Conferred over clod-squad on 2026-09-05 (messages 29681, 29683–29686).

The planner reports that commonplace-next's main pins this library at `778997e`;
this was independently confirmed with `git show main:mix.exs` in that repository
(the checked-out branch there has a different pin). The reviewed revision remains
relevant to that consumer main. The planner reports the deployed
Worker at `d0aff782`, while repository main is `60715aa`; registry work is landed
but awaits the KV namespace/binding/deployment sequence owned by boss-clod. These
are planner-reported operational facts, not deployment verification in this review.

The planner ranks preservation of **REALM-REMOVE-1b** above this maintenance list.
It identifies `/home/jes/astra-realm-remove` as an uncommitted eight-path change
based on `79edae4`, including adjudicated review edits, and has captured its state
under `/home/jes/commonplace-plan/docs/incoming/2026-09-05-fleet-takedown-state/`.
Its proposed bounded task is to compare against that capture, preserve the exact
content in a commit, and push a separate branch without landing or rewriting it.
The commit should identify implementer/reviewer and state that its D1–D3, R1–R6,
and typecheck checks remain unrun.

After preservation, the planner recommends comparing that candidate's reported
typecheck failure with its own `79edae4` base before attributing it to the change.
The passing typecheck in this review is at `778997e` and cannot answer that question.

One factual disagreement was returned to the planner: it initially said this repo
has no CI. `.github/workflows/ci.yml` exists at both reviewed and fetched revisions,
so finding 1 concerns a real configured workflow. Whether GitHub Actions is enabled
or executing it was not checked. This distinction does not settle the broader queue
priority, on which preservation of uncommitted work takes precedence.

The planner subsequently verified the workflow, retracted its no-CI claim, and
accepted the distinction between configuration and observed execution. It raised
the typecheck finding's priority but retained the rescue first because those
review edits are unique. **It is routing preservation to boss-clod**, which already
holds a do-not-clean guard on that worktree. The next proposed task for this reviewer
is the base-versus-candidate typecheck measurement, not an implementation change.

This review records the proposed handoff; it does not modify the separate removal
worktree, implement these improvements, or perform a deployment.
