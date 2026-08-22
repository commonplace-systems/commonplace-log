# Commonplace Monotonic Log 0.1 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement spec 0.1-draft end to end — a SQLite-backed Cloudflare Durable Object authority, an Elixir `Commonplace.LogStore` behavior with SQLite and Cloudflare adapters, and frontier/range synchronization — with every backend verified against one shared conformance corpus.

**Architecture:** Multi-writer append-only log: each writer owns a gapless sequence, a log is the union of writer sequences, replicas merge by pointwise longer compatible prefix. One repo, three stacks: `conformance/` (language-neutral test vectors), `worker/` (TypeScript Durable Object + gateway), `commonplace_log/` (Elixir library). One conformance suite runs against every adapter.

**Tech Stack:** TypeScript + Wrangler + `@cloudflare/vitest-pool-workers` (Durable Object with SQLite storage, tested locally); Elixir + `exqlite` (no Ecto) + `req` (HTTP adapter) + `stream_data` (property tests); RFC 8785 JCS implemented in **both** runtimes and proven byte-identical by shared fixtures.

**Status: APPROVED.** jes approved this plan and all §7 defaults 2026-08-21 23:10Z, and answered the one non-default question (Q3, immutability triggers: yes) at 23:13Z. The decision ledger is in §7. Section 8 is the execution-ready task list for Sub-project 1; later sub-projects get their own task-level plans as they start.

**Scope discipline:** The spec's §2 exclusions are decisions, not gaps. This plan adds no Merkle trees, no content-addressed IDs, no CRDT semantics, no total order, no consensus, no deletion/compaction, no signatures/capabilities. Where I think an internal-only addition is useful (e.g. immutability triggers, an audit query), it is flagged below as a proposal for jes — never silently built.

---

## 1. What gets built first, and its verifying artifact

**First deliverable: the shared canonicalization conformance kit** — a committed corpus of RFC 8785 vectors under `conformance/`, plus a JCS canonicalizer + entry validator in TypeScript **and** in Elixir, plus a harness that makes both runtimes emit canonical bytes for every vector and byte-diffs the outputs.

Why this first, not the Durable Object:

- §14 makes it a MUST: "Canonical JSON conformance vectors MUST be shared between the TypeScript Durable Object and Elixir adapters. An entry created in either runtime must produce identical canonical bytes in the other." Every later component (entry equality, duplicate detection, `entry_id_collision`, frontier equality) silently depends on this property. If the two runtimes disagree by one byte, replicas that are semantically identical report collisions. It is the highest-risk cross-cutting requirement (see §6 below) and it is cheap to prove early and expensive to discover late.
- **It is verified from artifacts, not reports:** the vectors are files anyone can read; the verdict is a `diff` over emitted byte files, not a test runner's exit code. The harness includes a deliberately-wrong vector case to demonstrate the gate can go red (a gate never seen red is not known to work), and known-good vectors demonstrate it stays green.
- The spec's own Phase 1 already includes "canonical JSON fixtures"; this is that item pulled to the front, not new scope.

## 2. Sub-project split and proposed order

Each sub-project produces working, independently testable software and gets its own detailed task plan.

| # | Sub-project | Spec source | Verifying artifact |
|---|---|---|---|
| SP1 | Conformance kit: shared vectors + JCS + entry validation in TS and Elixir | §7, §7.1, part of §19 Phase 1 | Committed vector corpus; byte-diff harness green over both runtimes; demonstrated red case |
| SP2 | `CommonplaceLog` Durable Object: schema init, transactional merge, append, frontier, writer range, local tail, §11 HTTP surface | §9, §11, §12, §19 Phase 1 | §18 tests 1–12 passing under `vitest-pool-workers` against real DO SQLite storage, locally, with on-disk state inspectable |
| SP3 | Elixir local replica + sync: `Commonplace.LogStore.SQLite`, writer identity locking, `Commonplace.Log.Sync` frontier/range engine | §10, §12, §14, §19 Phase 3 | Same conformance suite green over the SQLite adapter; two-replica convergence tests (11, 3, 4, 5) runnable entirely on this box; a live DO-in-dev ↔ Elixir sync demo over localhost HTTP |
| SP4 | Cloudflare bridge: Container outbound handler for `logs.internal`, `Commonplace.LogStore.Cloudflare` HTTP adapter | §13.1, §14, §19 Phase 2 | Conformance suite green over the Cloudflare adapter pointed at `wrangler dev`; §18 tests 14–15 |
| SP5 | Deployment + integration with existing Commonplace | §13, §19 Phase 4, §20 | Acceptance criteria of §20 |

**Proposed deviation from §19, for jes to accept or reject:** the spec orders Phase 2 (BEAM access via Container) before Phase 3 (local replica + sync). I propose swapping them (SP3 before SP4) because:

1. Everything through the hard acceptance criteria — disconnected append, bidirectional convergence, loud fork failure, no global order — is verifiable **on this machine** with SP2+SP3, no Cloudflare account provisioning in the loop.
2. The Cloudflare adapter is a thin HTTP client; it is better written against an HTTP protocol already exercised end-to-end by SP2's tests and SP3's sync engine, so bridge bugs can't hide inside protocol bugs.
3. SP4 needs account/wrangler/Container logistics from jes; SP3 does not. The swap removes him from the critical path for longer.

**Deferred (confirmed by jes):** the `Commonplace.LogStore.CubDB` migration adapter (§13.2 says "temporarily", §14 "recommended"). It only matters at SP5 integration time; building it earlier is speculative. Flagged, not dropped.

## 3. §8 invariants: checkable by test vs. held by construction

"Construction" means the code has no path that can violate it; those still get red-path tests where a violation *attempt* must be rejected. §18 test numbers in parentheses.

| Inv | Statement | How held | How checked |
|---|---|---|---|
| 1 | Committed entries never updated/deleted | Construction: no UPDATE/DELETE statement targets `entries` anywhere | Test: after rejected fork/collision attempts (8, 9), re-read and byte-compare the original entry. **Approved by jes (§7 Q3):** belt-and-braces SQLite `BEFORE UPDATE/DELETE ... RAISE` triggers on `entries` — built in SP2 as an ADDITION on top of the verbatim §12 DDL (if implementing them would require altering anything the spec pins, stop and re-ask), with the trigger's refusal demonstrated by red-path tests: attempt the UPDATE and the DELETE, assert the raised error, record the error text |
| 2 | Ack only after durable commit | Construction: reply is sequenced after transaction commit; DO uses `transactionSync`; local SQLite `synchronous=FULL` | Fault-injection test: crash between commit and reply, restart, entry present (2, 14). Partially testable; ordering itself is by construction |
| 3 | `(writer_id, writer_seq)` names ≤ 1 entry | Schema: `UNIQUE (writer_id, writer_seq)` | Red-path test (8): conflicting coordinate → `writer_fork`, no mutation |
| 4 | `entry_id` names ≤ 1 canonical entry | Schema: `UNIQUE (entry_id)` + byte-compare on duplicate | Red-path test (9): same UUID, different bytes → `entry_id_collision` |
| 5 | Every stored sequence is a complete prefix from 1 | Construction: merge/append admit only tip+1 | Property tests + gap rejection (6). Plus an **audit query** (test-support, not an API): writers where `COUNT(*) ≠ MAX(writer_seq) ≠ tips.last_seq` — run after every conformance scenario so the invariant is re-proven from stored state, not from the code path that wrote it |
| 6, 7 | Entry 1 has null prev; entry n names n−1 | Insert-time validation | Red-path tests (6, 7) + audit self-join `entries n ⋈ n−1 on prev_entry_id` |
| 8 | Entry `log_id` matches target log | Insert-time check against `log_meta` | Test: wrong `log_id` → `invalid_entry`; wrong store → `log_mismatch` |
| 9 | Identical retry is a successful no-op | Construction: duplicate detection by canonical bytes | Tests (1, 2): repeat append/merge; count stays 1; `present` reported |
| 10 | Failed batch leaves no partial writes | Construction: single transaction | Test (10): poison entry mid-batch → zero rows inserted, tips unchanged |
| 11 | Local metadata never changes identity/merge | Construction: `arrival_seq`/`received_at_ms` excluded from canonical bytes, frontier, export | Tests (11, 12): replicas fed in different orders converge to equal frontiers and equal canonical bytes with different arrival orders |
| 12 | Deletion = application tombstone append | Construction at this layer: no delete API exists | Not testable here (application-level convention); documented in the store's module docs |

## 4. §12 SQLite schema: where it pins us, where choice remains

**Pinned (implemented verbatim, no creativity):** the DDL as written — STRICT tables, names, column types, `CHECK` constraints, `AUTOINCREMENT` arrival cursor, the 1 MiB blob check, both UNIQUE constraints, the `entries_by_writer` index, `writer_tips` maintained in the same transaction as inserts. One physical database per logical log; `log_id` omitted from rows but present in `canonical_json` and verified against `log_meta` on every insert. The seven-step merge transaction of §12.1. DO: `transactionSync` + `sql.exec`. Local: explicit write transaction, `PRAGMA synchronous = FULL`.

**Left open — my picks, all reversible implementation detail:**

| Choice | Pick | Note |
|---|---|---|
| Local multi-log file layout | `<data_dir>/<log_id>.sqlite3`, one file per log | Forced structurally by "one physical database stores one logical log"; only naming is ours |
| Journal mode (local) | WAL (spec: MAY) + `synchronous=FULL` | Reader concurrency for projectors |
| Per-log write serialization (Elixir) | One GenServer per open log owning the write connection | Also carries the writer's exclusive-append lock (§6.2, §9.2) |
| Local writer identity storage | **Sidecar file next to the DB** (`<log_id>.writer`), plus a boot-time exclusive `flock` on it | §12 has no table for it — deliberately, I think: identity inside the DB travels with a clone. Sidecar + flock handles "original still active"; a full directory copy still defeats it, and §15.4 fork detection is the designed backstop. Fork response: report, stop the writer, never pick a branch |
| `read_writer` continuation cursor | Last `writer_seq` returned (opaque integer at HTTP layer) | Spec requires a cursor, not its shape |
| UUID casing on input | **Reject** non-lowercase as `invalid_entry`, never normalize | Matches "no additional fields" strictness; normalizing would make two byte-different entries "equal" |
| Big integers in `body` | Reject integers outside ±(2^53−1) at validation | I-JSON MUST; critical because Elixir would happily hold what JS silently mangles |
| Elixir SQLite driver | `exqlite` raw, no Ecto | Behavior's `Ecto.UUID.t()` is just a string typespec; Ecto buys nothing here. Without the Ecto dep the remote type won't resolve, so the behavior's typespecs use `String.t()` — the one deliberate delta from the §14 listing |

## 5. Elixir adapter boundary vs. the Durable Object

The `Commonplace.LogStore` behavior (§14, implemented verbatim) is the seam. Three consequences:

- **The sync engine sits above the behavior, not inside an adapter.** `Commonplace.Log.Sync` (§10) takes two `LogStore` instances and needs only `frontier/1`, `read_writer/3`, `merge/2` — so local↔local, local↔DO, and (later) DO↔DO sync are the same code, and sync is testable in SP3 with two local stores before Cloudflare exists.
- **`Commonplace.LogStore.Cloudflare` is a pure HTTP client** for the §11 protocol: Req with pooling, paging, idempotent-only retries (reusing identical entry objects, per §11.6), backpressure surfaced to callers, and a mechanical mapping from the error envelope to `{:error, {:writer_gap, %{expected_seq: …}}}`-style terms — the same terms the SQLite adapter returns, so callers can't tell backends apart by error shape. It never reports append success before the DO acknowledges commit. No Cloudflare SDK.
- **The Container outbound handler is Worker-side infrastructure** (TypeScript, SP4): it intercepts `http://logs.internal`, injects the authenticated scope, computes `idFromName("<scope_id>:<log_id>")`, and invokes the DO. The Elixir release stays Cloudflare-ignorant, which is what makes the SQLite and Cloudflare adapters honestly interchangeable.
- **One conformance suite, three backends:** the §18 suite is written once as an ExUnit case template parameterized by adapter, and its TS mirror drives the DO directly from the same `conformance/` fixture files. A backend is done when the shared suite is green over it, not when its own bespoke tests pass.

## 6. Top technical risk: cross-runtime RFC 8785

Called out so nobody discovers it in week three. JCS requires ECMAScript semantics that JavaScript gets for free and Elixir does not:

- **Number serialization** must match ECMAScript `Number::toString` exactly. Erlang's `float_to_binary(f, [:short])` gives the same shortest-round-trip digits, but its exponent/decimal formatting rules differ from ECMAScript at the boundaries (≥1e21, <1e-6). Needs a small formatting shim with targeted vectors on exactly those boundaries.
- **Key sorting** is by UTF-16 code units, not code points or UTF-8 bytes — these disagree for astral-plane characters (surrogates D800–DFFF sort before E000–FFFF). Elixir must compare keys via UTF-16 encoding. A fixture with astral + high-BMP keys makes this impossible to get quietly wrong.
- **String escaping** is exactly specified (short escapes, lowercase `\u00xx` for remaining controls).

This is why SP1 exists and comes first, and why both canonicalizers are hand-rolled small modules verified by the shared corpus rather than trusted dependencies (RFC appendix vectors + the boundary cases above + generated differential corpus).

## 7. Decision ledger (all questions answered by jes, 2026-08-21)

1. **Ordering** — SP3↔SP4 swap of §19's Phases 2 and 3: **YES** (23:10Z).
2. **CubDB adapter** — **DEFER to SP5-time** (23:10Z).
3. **Immutability triggers on `entries`** — **YES** (23:13Z, explicit answer, not blanket approval). Scope: an ADDITION to the verbatim §12 DDL; if they'd require altering a pinned column/constraint/index, that's a new question — stop and ask. The trigger's red path is built as a test (attempted UPDATE/DELETE must raise; error text recorded), which upgrades §3 invariant 1 from construction-only to test-checkable.
4. **Elixir code home** — **this repo, standalone library** (23:10Z).
5. **SP4 logistics** — **deferred** until SP4 (23:10Z).

---

## 8. Sub-project 1: conformance kit — task plan

**Files this sub-project creates:**

```
conformance/
  README.md                     # corpus format, how to run the harness
  check.sh                      # runs both emitters, byte-diffs outputs
  canonical-json/
    001-basic-object/input.json       # raw bytes as authored (never regenerated)
    001-basic-object/expected.hex     # canonical bytes, hex, one artifact per case
    ...
  invalid-entries/
    001-extra-top-level-field/input.json
    001-extra-top-level-field/error.txt   # expected error code
    ...
worker/
  package.json  tsconfig.json  vitest.config.ts
  src/jcs.ts                    # RFC 8785 canonicalizer
  src/entry.ts                  # version-1 entry validation
  test/jcs.test.ts  test/entry.test.ts
  scripts/emit-vectors.ts       # writes canonical bytes per vector to out/
commonplace_log/
  mix.exs
  lib/commonplace/log/jcs.ex
  lib/commonplace/log/entry.ex
  test/jcs_test.exs  test/entry_test.exs
  scripts/emit_vectors.exs
```

Vector corpus rules: `input.json` is authoritative **as bytes** (big-int and non-finite rejection cases can't survive a parse/reserialize round-trip); `expected.hex` is the canonical output, hex-encoded so no editor can mangle it; error cases carry `error.txt` instead. Corpus contents: RFC 8785 appendix vectors, the §6 boundary cases (number formatting boundaries, astral-plane key sorting, escaping table, unicode normalization non-cases), full valid entries from the spec's §7 example, and invalid entries covering every row of the §7 field table plus size cap.

### Task 1: TypeScript scaffold

- [ ] Create `worker/` with `package.json` (vitest, typescript), `tsconfig.json`, `vitest.config.ts`
- [ ] Add a placeholder test; run `npx vitest run` → 1 passing
- [ ] Commit: `chore(worker): scaffold TypeScript project with vitest`

### Task 2: Seed vector corpus

- [ ] Write `conformance/README.md` defining the corpus format above, **including a SELECTOR statement**: an explicit list of the input classes the corpus covers and the classes it deliberately does not — so a future green reads as "green over these classes," never as "green." Keep the statement updated in every task that adds vectors
- [ ] Author ~15 initial `canonical-json/` cases by hand: RFC 8785 appendix examples, key-sort cases (incl. astral), escaping cases, number boundary cases from both sides (`1e20`, `1e21`, `1e-6`, `0.000001`, `1e-7`, `-0`, `9007199254740991`), plus one case `999-deliberate-mismatch/` whose `expected.hex` is intentionally wrong, marked in README as the red-demonstration case
- [ ] Commit: `test(conformance): seed canonical JSON vector corpus`

### Task 3: TS canonicalizer, red then green

- [ ] Write `worker/test/jcs.test.ts`: for every corpus case, `canonicalize(parse(input))` bytes must equal `expected.hex` (skip-list the `999-` red case into its own inverted test asserting mismatch)
- [ ] `npx vitest run` → all corpus tests FAIL (`jcs.ts` absent)
- [ ] Implement `src/jcs.ts` (recursive serialize; UTF-16 key sort via native string compare on code units; per RFC 8785, `JSON.stringify` on individual strings/numbers already emits conforming output in a modern engine — only key ordering needs hand-rolling; the corpus is the arbiter either way)
- [ ] `npx vitest run` → corpus green, red-case test proves a wrong expectation is caught
- [ ] Commit: `feat(worker): RFC 8785 canonicalizer passing shared vectors`

### Task 4: TS entry validator, red then green

- [ ] Author `conformance/invalid-entries/` cases: each §7 field-table violation, extra top-level field, non-lowercase UUID, non-UTC timestamp, big int in body, >1 MiB canonical entry, non-finite number
- [ ] Write `worker/test/entry.test.ts` driving them; run → FAIL
- [ ] Implement `src/entry.ts` (`validateEntry(raw) → {ok, canonicalBytes} | {error: code}`); run → PASS. Big-int detection caveat: `JSON.parse` silently rounds `9007199254740993` to a *safe* integer, so a post-parse `Number.isSafeInteger` check never fires — use `JSON.parse`'s `context.source` reviver argument (modern V8) or a number-token scan of the raw bytes
- [ ] Commit: `feat(worker): version-1 entry validation passing shared vectors`

### Task 5: Elixir scaffold

- [ ] `mix new commonplace_log`; add `jason`, `stream_data` (test)
- [ ] `mix test` → placeholder passing
- [ ] Commit: `chore(elixir): scaffold commonplace_log library`

### Task 6: Elixir canonicalizer, red then green

- [ ] `test/jcs_test.exs` over the same corpus files; `mix test` → FAIL
- [ ] Implement `lib/commonplace/log/jcs.ex`: UTF-16 code-unit key sort, ECMAScript number formatting shim over `float_to_binary(:short)`, RFC escape table, big-int rejection
- [ ] `mix test` → green including the inverted red-case test
- [ ] Commit: `feat(elixir): RFC 8785 canonicalizer passing shared vectors`

### Task 7: Elixir entry validator

- [ ] Same shape as Task 4 against `invalid-entries/`; red, implement `entry.ex`, green
- [ ] Commit: `feat(elixir): version-1 entry validation passing shared vectors`

### Task 8: Cross-runtime byte-diff harness

- [ ] `worker/scripts/emit-vectors.ts` and `commonplace_log/scripts/emit_vectors.exs`: emit `out/<case>.bin` per corpus case
- [ ] `conformance/check.sh`: run both emitters, `diff -r` the two out-trees **and** diff each against `expected.hex` (decode hex with `xxd -r -p` first — never diff raw bytes against hex text); exits non-zero on any byte difference; prints per-case verdicts (never truncated)
- [ ] Demonstrate red: run with the `999-` case included → harness fails naming the case; record output in `conformance/README.md`
- [ ] Demonstrate green: run excluding it → clean; both facts noted in README
- [ ] Commit: `test(conformance): cross-runtime byte-diff harness (demonstrated red and green)`

### Task 9: Differential property fuzz

- [ ] StreamData generator for I-JSON values in Elixir; emit N generated cases + Elixir canonical bytes to a temp corpus; TS side canonicalizes the same inputs and diffs (files as the exchange medium — same harness)
- [ ] Fixpoint property both sides: `canonicalize(parse(canonicalize(x))) == canonicalize(x)`
- [ ] Any divergence found → minimized and frozen into `canonical-json/` as a permanent vector before fixing
- [ ] Commit: `test(conformance): cross-runtime differential fuzz`

### SP1 progress ledger

| Task | Status | Commits |
|---|---|---|
| 1 TS scaffold | done, reviewed | `a60b6f3` |
| 5 Elixir scaffold | done, reviewed (with `.tool-versions` OTP-27 pin, reviewer-verified necessary) | `cda0e53` |
| 2 corpus seed | done, spec+quality reviewed | `5b35b71`, `a60a1d3` |
| 3 TS canonicalizer | done, spec (incl. mutation probe + empty-corpus red) + quality reviewed | `8313a8f` |
| 4 TS entry validator | done, two review fix-rounds (calendar validation red-first; `context.source` load probe; value-based integer fields pinned by 018/030) | `825878d`, `b31bec7`, `f4ee6d4`, `5f33301` |
| 6 Elixir canonicalizer | done, spec (39-value differential vs node, 0 mismatches) + quality reviewed | `ac110b2`, `9e75a4b` |
| 7 Elixir entry validator | done, spec (slug lockstep audit; 13 side-by-side probes) + quality reviewed; unpinned classifier classes recorded in corpus README | `d659218`, `1c7bc90`, `0f49edb` |
| 8 byte-diff harness | done, adversarially reviewed (7 sabotage demos total across implementer+reviewer, all red-named-case) | `c076b18` |
| 9 differential fuzz | done, reviewed (recorded seeds reproduce; 2,500 cases, 0 divergences) | `03104e0` |

**SP1 exit criteria: MET (2026-08-22).** `conformance/check.sh` green over both runtimes (19 cases, TS≡Elixir≡expected, 999 mismatching as required); red paths demonstrated and recorded in `conformance/README.md`; fuzz (seeds 1166098830/500, 1074251894/2000) found no divergences, so no frozen vectors were needed. Suites: Elixir 1 doctest + 59 tests, TS 56 tests, all green.

**SP1 exit criteria:** `conformance/check.sh` green over both runtimes on the full committed corpus; the red path demonstrated and recorded; fuzz divergences (if any) frozen as vectors. Then SP2 (Durable Object) gets its detailed task plan.
