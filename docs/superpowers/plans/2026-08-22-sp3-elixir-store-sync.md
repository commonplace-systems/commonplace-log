# SP3: Elixir SQLite Store + Sync Engine — Task Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The local Elixir replica: the `Commonplace.LogStore` behavior (§14), the `Commonplace.LogStore.SQLite` adapter over exqlite with the verbatim §12 schema + triggers, writer identity with clone/rekey semantics (§6.2), and the adapter-agnostic `Commonplace.Log.Sync` frontier/range engine (§10) — with §18 conformance items 1–12 green over the SQLite adapter and two-replica convergence proven entirely on this machine.

**Architecture:** Mirror of SP2's shape in Elixir: a pure merge classifier module (ported behavior-for-behavior from `worker/src/do/merge-plan.ts`, in lockstep like jcs/entry), a store module executing plans inside SQLite transactions, and one GenServer per open log owning the write connection (the §6.2 exclusive-append lock within the node). The sync engine sits ABOVE the behavior and needs only `frontier/1`, `read_writer/3`, `merge/2` — so local↔local sync is fully provable now; the live DO↔Elixir demo moves to SP4 where the HTTP adapter exists (recorded deviation from the parent plan's SP3 artifact row — the demo needs the SP4 client either way, and local↔local proves the engine).

**Tech Stack:** `exqlite` (raw, no Ecto — behavior typespecs use `String.t()` per the recorded SP1 delta), existing `jason`/`stream_data`. No other new deps.

**Parent plan:** `2026-08-21-commonplace-log-v0.1.md` (§4 decisions: one file per log `<data_dir>/<log_id>.sqlite3`; WAL + `synchronous=FULL`; per-log GenServer; writer identity in a sidecar file, NOT in the DB). Spec: §§5, 6.2, 8, 9, 10, 12, 14, 15, 18.

**Standing constraints (unchanged):** red before green; gates demonstrated able to fire; anti-vacuity floors; no truncated verdicts; §2 exclusions stay excluded; §12 DDL verbatim (same byte-fidelity gate as SP2, reading the spec file); triggers pure addition; lockstep modules (`merge_plan` ↔ `merge-plan.ts`) state their twin in moduledocs.

## Design decisions locked here

- **Writer exclusivity = per-log GenServer (in-node serialization) + an exqlite-native cross-process lock (§6.2 MUST).** Within one BEAM node, the `Registry`-keyed `Commonplace.Log.SQLite.Server` serializes appends. Cross-OS-process exclusivity — the case §6.2's MUST exists for — comes from SQLite itself, which already does OS-level file locking: the Server holds a persistent exqlite connection to a dedicated `<log_id>.lock.sqlite3` with an open exclusive write transaction; any second process (or connection) attempting the same lock gets `SQLITE_BUSY` and the Server refuses to start. No new dependency — exqlite is already the C dep. (Plan-review correction: the first draft downgraded the parent plan's approved flock pick to a best-effort pid sentinel on the false premise that a lock needs a new dep; the reviewer pointed out SQLite is the flock. Red-path: a second connection acquiring the lock must fail with SQLITE_BUSY — tested.) The full-directory-copy clone hazard remains, as the parent plan records, with §15.4 fork detection as the designed backstop.
- **Writer identity sidecar:** `<data_dir>/<log_id>.writer` holds the writer UUID. Missing sidecar ⇒ generate a fresh writer_id (the §6.2 clone-safe default: a copied DB without its sidecar gets a new identity). `rekey/1` API forces a fresh writer_id (operator action after §15.4 fork recovery).
- **Transactions:** explicit `BEGIN IMMEDIATE`/`COMMIT`/`ROLLBACK` via exqlite; `PRAGMA synchronous = FULL` (spec SHOULD) + WAL (spec MAY, for reader concurrency). Ack only after COMMIT returns (§8 inv 2).
- **Behavior:** `Commonplace.LogStore` exactly per §14 with `String.t()` typespecs; the SQLite adapter implements it; SP2's DO is reachable through the same behavior only in SP4 (Cloudflare adapter).
- **Error terms:** `{:error, {code_atom, details_map}}` where code atoms mirror §11.6 strings (`:writer_gap`, `:writer_fork`, `:entry_id_collision`, `:log_mismatch`, `:log_not_found`, `:invalid_entry`, `:entry_too_large`) and details keys mirror the wire fields — one place documents the mapping, tests pin it.
- **Sync engine (§10):** `Commonplace.Log.Sync.pull(local, remote, log_id, opts)` one-direction pass per the spec pseudocode; `sync/4` = pull both directions + repeat until frontier equality or `deadline_ms`; fork ⇒ `{:error, {:writer_fork, ...}}` reported, that writer stopped, other writers continue (§10 step 3, §15.4). Adapter-agnostic: takes two modules-or-pids implementing the behavior.
- **Audit query:** port SP2's `auditStore` to an Elixir test helper; every conformance scenario ends with it; demonstrated red once via trigger-legal direct INSERT.

## File structure

```
commonplace_log/
  lib/commonplace/log_store.ex            # the §14 behavior
  lib/commonplace/log/merge_plan.ex       # pure §9.3 classifier (lockstep twin of merge-plan.ts)
  lib/commonplace/log_store/sqlite.ex     # the adapter (public API, delegates to Server)
  lib/commonplace/log_store/sqlite/server.ex   # per-log GenServer: connection owner, txns, writer identity
  lib/commonplace/log_store/sqlite/schema.ex   # DDL verbatim + triggers (same fidelity gate as SP2)
  lib/commonplace/log/sync.ex             # §10 engine over the behavior
  test/merge_plan_test.exs  test/sqlite_store_test.exs  test/sqlite_conformance_test.exs
  test/sync_test.exs  test/support/audit.ex  test/support/chains.ex
```

## Tasks

### Task 1: Behavior + schema module
- [ ] `mix.exs`: add `{:exqlite, "~> 0.27"}`; `lib/commonplace/log_store.ex` behavior verbatim from §14 (String.t typespecs, moduledoc records the delta)
- [ ] `schema.ex` red-first with the SP2-style fidelity gate: test reads the spec file's §12 ```sql block, asserts the module's DDL string equals it whole-block (trailing-whitespace-only normalization) — plus perturbation control; triggers const separate; `init_schema(conn)` executes DDL then triggers; trigger red paths (UPDATE/DELETE raise, error text recorded) against a real exqlite connection
- [ ] Commit: `feat(elixir): LogStore behavior and §12 schema with triggers`

### Task 2: Merge classifier port (lockstep)
- [ ] `merge_plan.ex` ported behavior-for-behavior from `worker/src/do/merge-plan.ts` (moduledoc: lockstep constraint, twin path); same outcomes incl. `:invalid_batch` → wire `:invalid_entry` mapping note
- [ ] `merge_plan_test.exs` red-first: port the TS table's 19 rows + order-independence + ≥14 floor; add the collision-at-same-coord row (the SP2 mutant-killer)
- [ ] Commit: `feat(elixir): pure merge classification per §9.3 (lockstep with TS)`

### Task 3: SQLite store — create_log, append, writer identity
- [ ] Server GenServer: opens/creates `<data_dir>/<log_id>.sqlite3`, pragmas, schema init, sidecar read-or-generate, **exclusive lock acquisition on `<log_id>.lock.sqlite3` (fail to start on SQLITE_BUSY)**; `create_log` idempotent + `log_mismatch` both directions; `append` per §9.2 inside BEGIN IMMEDIATE…COMMIT, via SP1 `Entry.validate_entry` on canonical bytes (store never its own byte oracle), uuidv7 (port the SP2 layout; `:crypto.strong_rand_bytes`)
- [ ] Tests red-first: mirror SP2 Task 4's list (byte-fidelity vs independent construction, chaining, two writers, arrival_seq, rollback-by-effect with prior state, second-handle continuation, fault-injection rollback — inject via a poisoned statement or a transaction-wrapper hook so the txn is falsifiable from day one) + sidecar: fresh dir ⇒ new writer_id; sidecar present ⇒ stable across restarts; sidecar deleted ⇒ NEW writer_id (clone default); `rekey/1`; **lock red path: while a Server holds a log, a second lock attempt (second connection acquiring the exclusive lock) fails with SQLITE_BUSY and a second Server refuses to start; releasing (stopping the Server) frees it**
- [ ] Commit: `feat(elixir): SQLite store createLog/append with writer identity`

### Task 4: SQLite store — transactional merge + reads
- [ ] `merge` executing the classifier plan in one transaction (§12.1; fields derived from canonical bytes — inherit the SP2 Task 5 lesson: the raw input is read once by the canonicalizer, never re-read); `frontier` (sorted), `read_writer` (exclusive/inclusive, cursor), `tail_local`
- [ ] Tests red-first: mirror SP2 Tasks 5+6 lists (poison batch both-writers-rollback; fork leaves bytes intact; log_id mismatch inside valid entry; paging reassembly byte-for-byte; arrival-vs-writer divergence non-vacuous; limit-exactly-remaining cursor null)
- [ ] Commit: `feat(elixir): transactional merge and reads per §12.1`

### Task 5: §18 conformance 1–12 over the SQLite adapter
- [ ] Port SP2's conformance suite shape (NOTE for the porter: §18.1/18.2 idempotence is proven via identical MERGE batches, as in SP2 — `append/4` generates a fresh entry_id per call, so repeating append would be the wrong test and a vacuous green): spec-numbered tests, exactly-12 registry gate, audit helper (SQL-only) after every scenario + demonstrated red, restart analog (§15.2: kill the Server process, reopen from disk, everything rebuilt from SQLite; acked entries survive — this is the §18.14-adjacent local variant, still labeled §18.2)
- [ ] Replica pairs = two data_dirs; both sync orders on independent pairs; §18.12 timestamp reading as in SP2
- [ ] Commit: `test(elixir): §18 conformance 1–12 over the SQLite adapter`

### Task 6: Sync engine
- [ ] `sync.ex` red-first per the §10 pseudocode: snapshot frontiers, per-writer compare (equal seq ⇒ entry_id MUST match else fork), pull ranges page-wise through the behavior, merge idempotently, repeat until equal frontiers or deadline; fork stops ONLY that writer (others still sync — test it)
- [ ] Tests: two SQLite replicas — §18.3 both orders via the ENGINE (not hand-rolled pulls); page-size sweep (1, 2, 7); deadline expiry returns progress-so-far; fork reported with both tips; writers advancing DURING sync converge on repeat (§10 "repeats if newer entries appeared")
- [ ] Commit: `feat(elixir): frontier/range sync engine per §10`

### Task 7: Merge-law property tests (§18 SHOULD)
- [ ] StreamData: random writer sets, chain lengths, partition points, batch boundaries, duplicate deliveries, sync orders → assert §5 laws (idempotent, commutative, associative, monotone) over real SQLite replicas; seeds printed; ≥200 cases per property locally (keep runtime modest); any counterexample minimized and frozen as a regression test before fixing
- [ ] Commit: `test(elixir): §5 merge-law properties over SQLite replicas`

### Task 8: SP3 close-out
- [ ] Full sweep: `mix test` + `mix format --check-formatted` + worker suites + `conformance/check.sh` all green; parent ledger updated **including an explicit amendment of the parent's SP3 artifact row (DO↔Elixir demo moved to SP4, where its HTTP-client dependency lives)**; memory updated
- [ ] Commit: `plan: SP3 complete`

**SP3 exit criteria:** §18 items 1–12 green over the SQLite adapter; sync engine converges two local replicas in either order under the engine (not hand-rolled); merge-law properties green with recorded seeds; writer identity clone/rekey semantics tested; single-node lock scope + cross-process limitation documented loudly; no §2 exclusion added; all prior suites still green.
