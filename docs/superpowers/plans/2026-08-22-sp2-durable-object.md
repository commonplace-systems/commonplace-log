# SP2: CommonplaceLog Durable Object — Task Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The `CommonplaceLog` SQLite-backed Durable Object: §12 schema (verbatim DDL + jes-approved immutability triggers), §9 store operations with the §12.1 transactional merge, the §11 HTTP surface, and §18 conformance tests 1–12 passing against real DO SQLite storage locally.

**Architecture:** Store logic lives in plain TypeScript modules operating on the `SqlStorage` interface (testable, reviewable in isolation); the DO class is a thin shell wiring `ctx.storage` + `transactionSync` + HTTP routing to those modules. Entry validation and canonicalization are SP1's `worker/src/entry.ts` / `jcs.ts`, reused, never re-implemented. Tests run under `@cloudflare/vitest-pool-workers` against real DO SQLite storage (workerd), alongside the existing plain-node unit suite via a vitest projects split.

**Tech Stack:** wrangler + `@cloudflare/vitest-pool-workers` (workerd with `new_sqlite_classes` migration for the DO), TypeScript strict. No production dependencies.

**Parent plan:** `2026-08-21-commonplace-log-v0.1.md` (SP2 row; jes-approved decisions in its §7 ledger). Spec: `docs/commonplace-monotonic-log-spec.md` §§8–13, §18.

**Standing constraints carried from SP1:** red before green on every behavior; every gate demonstrated able to fire; anti-vacuity floors on discovered/derived collections; no truncated verdict lines; the spec's §2 exclusions stay excluded; §12 DDL verbatim — the triggers are an ADDITION, and if implementing them would require altering any pinned column/constraint/index, STOP and re-ask jes.

---

## File structure

```
worker/
  wrangler.jsonc                 # DO binding COMMONPLACE_LOG, new_sqlite_classes migration
  vitest.config.ts               # becomes a projects split: unit (node) + do (workers pool)
  vitest.workers.config.ts       # workers-pool project config (wrangler-aware)
  src/
    do/schema.ts                 # §12 DDL verbatim as one exported const; triggers as a SEPARATE exported const
    do/store.ts                  # createLog/append/mergeBatch/frontier/readWriter/tailLocal over SqlStorage
    do/merge-plan.ts             # pure batch classifier: (batch, tips) -> per-writer plan | typed error
    do/errors.ts                 # error codes + §11.6 envelope construction (one spelling site)
    do/http.ts                   # §11 routing: parse/limit-check/dispatch/serialize
    commonplace-log-do.ts        # the DO class: transactionSync glue + fetch() -> http.ts
    index.ts                     # worker entry exporting the DO class
  test/do/
    schema.test.ts  merge-plan.test.ts  store.test.ts  http.test.ts  conformance.test.ts
    helpers.ts                   # audit-query runner, entry factories (built on SP1 validators)
```

## Design decisions locked here

- **Triggers (jes-approved, Q3):** `CREATE TRIGGER entries_no_update BEFORE UPDATE ON entries ... RAISE(ABORT, 'entries are immutable')` and the DELETE twin. Executed AFTER the verbatim DDL, in the same schema-init step. Red-path tests attempt both and assert the raised error text — the recorded error text is the artifact.
- **Merge classification is a pure function** (`merge-plan.ts`): takes the validated batch + current writer tips, returns either `{perWriter: [{writerId, newEntries, expectedFirstSeq}]}` or a typed error (`writer_gap` with receiver tip, `writer_fork`, `entry_id_collision`, intra-batch duplicate/inconsistency). All §9.3 rules 1–6 live here, table-driven-testable without a database. `store.ts` then executes the plan inside one transaction.
- **Errors:** one `errors.ts` table maps code → HTTP status per §11.6 (the envelope shape is spec-pinned). `invalid_entry`/`entry_too_large` reuse SP1's validator codes/slugs untouched (`reason` slug rides in `details`).
- **Audit query as test infrastructure** (parent plan §3, invariant 5–7): after every conformance scenario, `helpers.ts` re-proves from stored state: per writer `COUNT(*) == MAX(writer_seq) == writer_tips.last_seq`, entry n's `prev_entry_id` = entry n−1's `entry_id`, entry 1's prev is null. Runs as an assertion, not decoration — one test deliberately corrupts a scratch store to show the audit fails (via a direct SQL INSERT bypassing the store — allowed in tests only, and possible because triggers guard UPDATE/DELETE, not INSERT).
- **Restart durability (test 2/§15.2 analog):** vitest-pool-workers' `runInDurableObject` + aborting the object between operations; storage persists within a test's isolated storage scope. Verify tips reconstruction reads from SQLite, not memory (store keeps NO in-memory correctness state — by construction; the test kills and re-reads).
- **DO name ↔ log_id verification (§13.1):** the DO reads its name via `ctx.id.name`, verifies against `log_meta.log_id` on every request family; mismatch → `409 log_mismatch`. (Scope prefixing `<scope_id>:` is SP4's concern; SP2 accepts a bare `log_id` name and documents that.)
- **Batch limits:** 100 entries / 4 MiB canonical bytes per §11.2, checked before expensive parsing per §16 (content-length gate first, then per-entry).
- **Observability (§17 SHOULD):** a `stats()` internal method returning counts (entries, writers, inserted/duplicate counters since boot) exposed only on the internal debug route `GET /v1/logs/{log_id}/stats`; no metrics exporters (later sub-project). Bodies never logged.

## Tasks

### Task 1: Workers test tooling scaffold
- [ ] Add devDeps `wrangler` and **`@cloudflare/vitest-pool-workers` pinned to `0.12.x`** — DECIDED: we stay on the legacy line. Cloudflare renamed the integration to `@cloudflare/vitest-plugin` on 2026-08-19 (requires vitest ≥4.1, removes `defineWorkersProject`); the repo is on vitest ^3.2.4 and `@latest` hits a peer-dependency wall. Migrating to vitest 4 + the new plugin is a recorded follow-up for after SP2, not mid-project churn. `wrangler.jsonc` with DO class `CommonplaceLog`, binding, `new_sqlite_classes` migration; split vitest into projects: existing unit suite (node) untouched + `test/do/**` under the workers pool
- [ ] Smoke test: a trivial DO echoing `ctx.storage.sql.exec("select 1")` via `runInDurableObject`; see it RED first (missing class), then green; confirm the plain unit project still passes 56
- [ ] Commit: `chore(worker): workers-pool test tooling for the Durable Object`

### Task 2: Schema + immutability triggers
- [ ] `schema.test.ts` red-first: init runs; all three tables + index exist with STRICT; re-init idempotent; **trigger red paths: UPDATE and DELETE on a committed entry each raise, error text asserted and recorded in the test name/comment**; INSERT still works after triggers
- [ ] `do/schema.ts`: §12 DDL byte-verbatim from the spec (copy, don't retype — a test asserts the DDL const contains the spec's exact `CREATE TABLE` bodies) + separate triggers const; green
- [ ] Commit: `feat(do): §12 schema with immutability triggers (red-path tested)`

### Task 3: Merge-plan pure core
- [ ] `merge-plan.test.ts` red-first, table-driven over §9.3: empty batch; fresh writer from seq 1; extension at tip+1; exact-duplicate suffix (idempotent, reports present); gap (returns receiver tip); fork at occupied coordinate; entry_id collision (same id, different canonical bytes — and same id SAME bytes at same coordinate = duplicate, not collision); intra-batch gap; intra-batch duplicate entry_id; multi-writer batch mixing all of the above; prev_entry_id chain violations (first new entry must name local tip; later entries name preceding batch entry); wrong log_id
- [ ] Implement `do/merge-plan.ts`; green. Anti-vacuity: the table has ≥14 rows, asserted
- [ ] Commit: `feat(do): pure merge classification per §9.3`

### Task 4: Store — createLog + append
- [ ] `store.test.ts` red-first: createLog idempotent (§9.1); reusing a store for a different log_id → log_mismatch; append allocates seq 1 with null prev, then tip+1 chaining; canonical bytes stored (byte-compare vs SP1 canonicalizer); arrival_seq assigned; tips row updated in same transaction (crash-sim: a poisoned append leaves no partial state)
- [ ] Implement in `do/store.ts` using `transactionSync`; green
- [ ] Commit: `feat(do): createLog and append`

### Task 5: Store — transactional merge
- [ ] Red-first: mergeBatch happy paths (fresh writer, extension, duplicates reported as `present`); §18 test 6 (gap → no partial insertion — poison in the MIDDLE of a multi-writer batch, assert ZERO rows and unchanged tips for ALL writers, test 10); fork rejection leaves original bytes intact (re-read + byte-compare, invariant 1); collision rejection; returns post-merge frontier
- [ ] Implement (execute merge-plan inside one `transactionSync`); green; audit query passes after every scenario. The store must also verify each entry's `log_id` (parsed upstream, inside the canonical bytes) against `log_meta` per §8 invariant 8, with a test — the pure classifier deliberately has no log identity (Task 3 deferral: `BatchEntry` carries no `logId`)
- [ ] Commit: `feat(do): transactional batch merge per §12.1`

### Task 6: Store — frontier, readWriter, tailLocal
- [ ] Red-first: frontier sorted by writer_id (§9.4, stability asserted with ≥3 writers inserted out of order); empty-log frontier = empty writers array; readWriter exclusive-after/inclusive-through, contiguity, limit + continuation cursor (last returned seq), beyond-tip clamping; tailLocal by arrival order with cursor, explicitly different from writer order in the test (interleave two writers)
- [ ] Implement; green
- [ ] Commit: `feat(do): frontier, writer-range, and arrival-tail reads`

### Task 7: HTTP surface
- [ ] `http.test.ts` red-first against the DO via `runInDurableObject`/SELF fetch: all five §11 routes; success shapes (§11.2 response with inserted/present/frontier); every §11.6 error mapped (status + envelope, incl. 404 pre-create, 409 triplet with details, 413 both codes, 422 with SP1 reason slug in details, batch >100 entries and >4 MiB rejected BEFORE parse — content-length gate observable); name↔log_id mismatch → log_mismatch; **`ctx.id.name === undefined`** (object reached via `idFromString()`/`newUniqueId()` — name is only populated via `idFromName()`/`getByName()`) → explicit rejection: 409 `log_mismatch` with a details message naming the unverifiable object name, its own test row — never an accidental `undefined !== log_id` fall-through; malformed JSON → 400. `errors.ts` carries the full §11.6 code→status table INCLUDING `507 storage_full` (not simulable in local workerd; a unit test on the table alone pins its spelling; 401/403 are gateway-side, SP4). DECIDED (Task 3 review): merge-plan's internal `invalid_batch` maps to **422 `invalid_entry`** on the wire — an intra-batch prev-linkage violation breaks §7's relational requirement, so the batch is malformed as submitted, unlike gap/fork receiver-state conflicts
- [ ] NOTE (Task 5 review): the HTTP layer owns `batch_too_large` enforcement — the §11.2 advertised limits (100 entries / 4 MiB) are protocol-surface concerns the store does not check. NOTE (Task 5 review): the HTTP layer must map StoreError camelCase details to §11.6 snake_case wire fields (`expectedSeq` → `expected_seq`, `tipEntryId` → `tip_entry_id`, `writerId` → `writer_id`, `entryId` → `entry_id`).
- [ ] Implement `do/http.ts` + `commonplace-log-do.ts` + `index.ts`; green; `stats()` debug route
- [ ] Commit: `feat(do): §11 HTTP protocol`

### Task 8: §18 conformance suite (tests 1–12) + restart durability
- [ ] `conformance.test.ts`: one named test per §18 item 1–12 (names carry the spec numbers), driven through the HTTP surface where meaningful (append idempotence via identical re-POST; lost-ack retry; two-writer convergence in either order using two store instances merged both ways; three-way associativity; page-by-page extension; gap/fork/collision rejections; mixed-writer atomicity; arrival-order divergence with converged frontiers; timestamp irrelevance). Restart test: write → evict the object (`evictDurableObject()`, the documented vitest-integration teardown helper) → re-read via fresh instance, acknowledged entries present, tips rebuilt from SQL; per the isolated-storage docs, await all storage promises before eviction
- [ ] Anti-vacuity: exactly 12 spec-numbered tests asserted present; audit query after each; all green with full run pasted
- [ ] Commit: `test(do): §18 conformance 1–12 against real DO storage`

### Task 9: SP2 close-out
- [ ] `tsc --noEmit` clean; full vitest (both projects) green; `conformance/check.sh` + `mix test` regressions green; parent-plan ledger row updated
- [ ] Commit: `plan: SP2 complete`

**SP2 exit criteria:** §18 tests 1–12 green under workers pool against real DO SQLite; trigger red paths recorded; audit query green after every scenario and demonstrated able to fail; both SP1 suites and the harness still green; no §2 exclusion added; DDL verbatim with triggers as pure addition.
