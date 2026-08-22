# SP3: Elixir Engine, Persistence, and Sync — Task Plan (REVISED)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**REVISION NOTICE (2026-08-22):** this plan was amended mid-flight per jes's BEAM-native revision (`docs/proposals/2026-08-22-beam-native-revision.md`, committed byte-identical at `31188f6`). Elixir is now NORMATIVE; the Durable Object is a conforming workalike; domain decisions move into `Commonplace.Log.Engine` over a `Commonplace.Log.Persistence` behavior (read-set → commit-plan → expected-revision commit). Tasks 1–2 were complete before the revision landed and survive per the proposal's own disposition table (§9): Task 1's schema becomes the LocalSQLite reference adapter schema; Task 2's classifier becomes normative (moduledoc rewording done in the Phase-0 commit). Tasks 3–5 below are the REVISED replacements for the original store tasks — the original Task 3/4 would have built classification into the store, exactly what §6 moves out. Tasks 6–7 (sync, properties) are unchanged in design per proposal §5.1.

**Goal:** The normative Elixir engine and local persistence: `Commonplace.Log.Engine` (entry construction, validation, classification, optimistic commit, retries), the `Commonplace.Log.Persistence` behavior (§6.3 of the proposal), the `LocalSQLite` adapter (one file per log, verbatim reference schema + triggers, writer identity with clone/rekey, exqlite-native cross-process lock), `Commonplace.LogStore.SQLite` composing Engine + adapter behind the public §14 behavior, §18 conformance 1–12 over that composition, the §10 sync engine, and §5 merge-law properties.

**Tech Stack:** exqlite (resolved 0.39.0), jason, stream_data. No other new deps.

**Parent plan:** `2026-08-21-commonplace-log-v0.1.md`. Spec: 0.1-draft §§5–15, 18, as amended by the proposal (protocol invariants normative; physical DDL adapter-specific). Proposal: `docs/proposals/2026-08-22-beam-native-revision.md` — its §6 persistence contract, §9 disposition table, and §14 mitigations are load-bearing here.

**Standing constraints (unchanged):** red before green; gates demonstrated able to fire; anti-vacuity floors; no truncated verdicts; §2/§3 exclusions stay excluded; triggers pure addition; domain errors originate in Elixir only — persistence adapters return storage errors (`:stale_revision`, constraint, storage-full), never `writer_fork` (proposal §14 "sidecar boundary becomes secretly semantic" applies to the LOCAL adapter too: it keeps adapters honest and identical in shape).

## Design decisions locked here

- **Persistence contract per proposal §6.3, implemented EXACTLY for both adapters** (LocalSQLite now, CloudflareSidecar in SP4): `create_log/3`, `read_set/3`, `commit/2` with `expected_revision` → `{:error, :stale_revision}` on mismatch, `frontier/2`, `read_writer/4`, `tail_local/3`. Locally the single writer GenServer means CAS can only fail if someone bypasses the engine — but the contract is honored identically so acceptance criterion 5 (same domain error for both adapters) holds by construction, and the Engine's stale-revision retry loop is property-tested via a wrapping adapter that injects staleness (proposal §14 mitigation).
- **Per-log revision, additive storage:** the pinned §12 reference schema has no revision column; the LocalSQLite adapter stores it in an ADDITIVE `persistence_meta` table (same addition-discipline as the triggers — the four pinned objects stay byte-verbatim, the fidelity gate keeps proving it). The revision advances by exactly 1 per committed plan.
- **Engine owns all domain semantics:** entry construction (uuidv7, prev-chaining), validation (`Commonplace.Log.Entry`), classification (`Commonplace.Log.MergePlan`), fields-derived-from-canonical-bytes (the SP2 Task 5 lesson — the raw input is consumed once by the canonicalizer; every stored column comes from the validated bytes), retry-on-stale. The Engine contains no Exqlite/HTTP/Cloudflare code (proposal §5.1); adapters contain no Entry/Jcs/MergePlan imports (a dependency test enforces this, per §14).
- **Writer exclusivity (unchanged from pre-revision correction):** in-node serialization via the per-log Server; cross-process exclusivity via an exclusive transaction held on `<log_id>.lock.sqlite3` — SQLite IS the file lock; second acquirer gets SQLITE_BUSY, red-path tested. Writer identity sidecar `<data_dir>/<log_id>.writer`; missing ⇒ fresh writer_id (clone-safe default); `rekey/1`.
- **Read-set coherence locally:** `read_set` executes its SELECTs inside one transaction so tips/coordinates/entry_ids/revision are one snapshot.
- **§18.1/18.2 idempotence via identical MERGE batches** (append mints fresh entry_ids; repeating append would be a vacuous green).
- **Spec amendment mechanics (Phase 0.2):** the 0.1 spec file stays byte-identical (provenance preserved); the normative delta lives in `docs/protocol/0.1-amendment-1-beam-native.md` pointing at the proposal. jes can direct a merged v0.2 later.

## File structure

```
commonplace_log/
  lib/commonplace/log_store.ex                 # §14 behavior (done, Task 1)
  lib/commonplace/log/merge_plan.ex            # normative classifier (done, Task 2)
  lib/commonplace/log/engine.ex                # Task 3: domain coordination + retry loop
  lib/commonplace/log/persistence.ex           # Task 3: the behavior + ReadSet/CommitPlan structs
  lib/commonplace/log/persistence/local_sqlite.ex        # Task 4: adapter
  lib/commonplace/log_store/sqlite.ex          # Task 5: public composition (LogStore impl)
  lib/commonplace/log_store/sqlite/schema.ex   # reference adapter schema (done, Task 1)
  lib/commonplace/log_store/sqlite/server.ex   # Task 4/5: per-log GenServer (conn owner, lock, identity)
  lib/commonplace/log/sync.ex                  # Task 6
  test/…                                       # mirrors, + test/support/audit.ex
```

## Tasks

### Task 1: Behavior + schema — DONE pre-revision (`75a4a20`), kept per proposal §9
### Task 2: Merge classifier — DONE pre-revision (`01aae15`, `cde7b79`), normative per proposal; moduledoc reworded in the Phase-0 commit

### Task 3: Persistence behavior + Engine
- [ ] `persistence.ex` red-first: the §6.3 behavior with `ReadSet` and `CommitPlan` structs exactly as the proposal shapes them (log_id, revision, tips, coordinates, entry_ids / log_id, expected_revision, insert_entries, put_tips); a `read_query` type naming affected writers/coordinates/entry_ids. Contract notes: the ReadSet maps `entry_id => canonical_bytes` ONLY — the Engine derives a stored owner's coordinate for `present_by_id` by parsing those canonical bytes (fields-from-canonical-bytes; parsing never crosses onto the adapter side). `insert_entries` rows carry canonical bytes + identity columns; `received_at_ms`/`arrival_seq` are ADAPTER-assigned local metadata (§8 inv 11), never CommitPlan fields — keeps both adapters identical in shape (criterion 5)
- [ ] `engine.ex` red-first, tested against a MAP-BACKED in-memory test adapter (implements the behavior; lives in test/support — it is test scaffolding, not a shipped adapter): `append/…` (construct entry per §9.2 semantics, validate, single-entry commit-plan), `merge/…` (validate batch — fields from canonical bytes — read_set for affected writers, `MergePlan.plan_merge` with lookups served FROM the read set, build commit plan, commit); stale-revision retry loop: a wrapper adapter injects `:stale_revision` N times → engine re-reads and succeeds on N+1, bounded retries (cap asserted; exceeding the cap surfaces a typed error); domain errors pass through unchanged; adapter storage errors surface as storage errors, never reclassified
- [ ] Dependency test: `engine.ex` source contains no Exqlite/HTTP references (grep-based test with positive control), and `persistence/*.ex` adapters contain no Entry/Jcs/MergePlan imports (asserted for the test adapter now, real adapters as they land)
- [x] Commit: `feat(elixir): persistence contract and normative engine` — DONE (`4c85253`, implemented by Sol, reviewed and landed by me). `mix test` 92 → 106; mutation probe (tips from first rather than last new entry) turns the suite red, so it is not decoration.

**Two notes this task's review surfaced, for the tasks that inherit them:**
- **[Task 5]** `Engine` returns TWO error shapes: `{:error, term}` for domain/storage tuples and `{:error, code, reason}` (3-tuple) propagated from `Entry.validate_entry/1`. That is honest at the Engine layer; the `LogStore` composition in Task 5 is where they normalize to the single recorded atom convention (`{:error, {:writer_gap, %{...}}}` etc. with wire-shaped details). Do not "fix" it in the Engine.
- **[SP4]** `Engine.append` mints a fresh `entry_id` on each stale-revision retry. Measured harmless today: the returned id always equals the stored id, and the Engine retries ONLY on an explicit `:stale_revision` (a commit that provably did not apply), passing every other error through. But the sidecar introduces a genuinely ambiguous outcome — a lost acknowledgement is not a stale revision. SP4 must therefore make `commit/2` idempotent, or have the adapter re-read and detect its own prior success, before any retry can be safely widened beyond `:stale_revision`.

### Task 4: LocalSQLite persistence adapter
- [ ] Red-first over a real exqlite file DB: `create_log` idempotent + `log_mismatch` both directions; `read_set` one-snapshot (single transaction; revision + tips + coordinates + entry_ids); `commit` applies plans atomically inside BEGIN IMMEDIATE (insert exact canonical rows, put exact tips, advance revision by 1, ack after COMMIT — §8 inv 2), `:stale_revision` on wrong expected_revision (constructed by a direct SQL revision bump between read and commit), fault-injection rollback (poisoned statement mid-plan → nothing persisted, revision unchanged — the falsifiable-transaction discipline from SP2), `persistence_meta` additive (fidelity gate untouched — re-run it), triggers still hold (UPDATE/DELETE raise), reads (`frontier` sorted / `read_writer` exclusive-after inclusive-through with cursor / `tail_local` arrival order) matching the behavior shapes
- [ ] Server GenServer: connection + lock + sidecar identity (lock red path: second acquirer SQLITE_BUSY, second Server refuses to start, release frees; sidecar: fresh/stable/deleted⇒new; `rekey/1`)
- [ ] Commit: `feat(elixir): LocalSQLite persistence adapter with writer identity and lock`

### Task 5: Public composition + §18 conformance
- [ ] `log_store/sqlite.ex`: implements the §14 `Commonplace.LogStore` behavior by composing Engine + LocalSQLite via the Server; error terms per the recorded atom convention (`:writer_gap` etc. with wire-shaped details)
- [ ] A filed dependency test for acceptance criterion 2: no file under `commonplace_log/` (lib or test) references `worker/` paths or imports workalike code — grep-based ExUnit test with positive control, so the gate fires rather than relying on a close-out sweep remembering it
- [ ] §18 conformance 1–12 ported from SP2's suite shape over THIS composition (spec-numbered names, exactly-12 registry gate, audit helper — SQL-only, extended to check `persistence_meta.revision` consistency: revision ≥ count of committed plans is not derivable, so check revision monotonicity across scenario steps instead — audit demonstrated red via trigger-legal direct INSERT), restart analog (kill Server, reopen from disk), both-orders convergence on independent replica pairs (two data_dirs)
- [ ] Commit: `test(elixir): §18 conformance 1–12 over Engine+LocalSQLite`

### Task 6: Sync engine (design unchanged by revision — proposal §5.1)
- [ ] `sync.ex` red-first per §10 pseudocode over the `Commonplace.LogStore` behavior: snapshot frontiers, per-writer compare (equal seq ⇒ entry_id MUST match else fork), page-wise pull, idempotent merge, repeat until equal or `deadline_ms`; fork stops ONLY that writer (others continue — tested)
- [ ] Tests: two local replicas, §18.3 both orders VIA THE ENGINE; page-size sweep (1, 2, 7); deadline returns progress; fork reported with both tips; writers advancing during sync converge on repeat
- [ ] Commit: `feat(elixir): frontier/range sync engine per §10`

### Task 7: Merge-law property tests (§18 SHOULD; unchanged)
- [ ] StreamData: random writer sets/chains/partitions/batch boundaries/duplicate deliveries/sync orders → §5 laws over real replicas; seeds printed; ≥200 cases/property, runtime modest; counterexamples frozen before fixing. PLUS the proposal-§14 property: engine retry under randomly injected stale revisions never loses, duplicates, or reorders entries
- [ ] Commit: `test(elixir): §5 merge-law and stale-retry properties`

### Task 8: SP3 close-out
- [ ] Full sweep (mix + worker + check.sh + fuzz spot-run); parent ledger updated INCLUDING: SP3 artifact row amended (DO↔Elixir demo → SP4, where its client dependency lives), SP4 row replaced per proposal §9 (`Persistence.CloudflareSidecar` + realm Container DO + optional `LogStore.WorkalikeClient`), SP2 row annotated "complete as the Durable Object workalike milestone"; `docs/protocol/0.1-amendment-1-beam-native.md` present; memory updated; NOTE in the ledger: proposal-§12 persistence-conformance's `storage_full` behavior is deferred to SP4's shared persistence suite (not locally simulable), recorded so it isn't silently dropped
- [ ] Commit: `plan: SP3 complete`

**SP3 exit criteria:** proposal acceptance criteria 1, 2, 5 (local half) demonstrably hold: the Elixir suite is the normative source for entry/merge semantics; disabling `worker/` leaves the Elixir implementation complete (its tests never import worker code — grep-provable); Engine produces identical domain errors over LocalSQLite and the in-memory test adapter. §18 items 1–12 green over Engine+LocalSQLite; sync converges both orders via the engine; properties green with seeds; lock/identity semantics tested; all prior suites (worker 218, conformance harness, fuzz) still green — the workalike stays green per proposal Phase 5.1.
