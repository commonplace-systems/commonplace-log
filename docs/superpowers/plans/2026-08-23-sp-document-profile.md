# SP-DP: Cell-Owned Document Profile — Task Plan

> **For agentic workers:** implementation goes to Sol. Steps use checkbox (`- [ ]`) syntax.

**Source:** `docs/proposals/2026-08-22-cell-owned-document-profile.md` (jes). A **restricted application profile** over the existing protocol, not a new entry format. Everything in its §17.1 "Preserve" list stays.

**Goal:** Make ordinary Document logs single-lane by construction — one log, one lifetime append lane, one fenced appender — without callers ever naming a `writer_id`, and without a read ever creating storage.

---

## 1. Measured starting position

I probed the current implementation against the profile's §17.3 list rather than reading it against the code. Four gaps are real and measured; several requirements already hold.

**Violations, measured 2026-08-23:**

| # | Profile requirement | Measured behaviour today |
|---|---|---|
| V1 | §7: reading an unknown `log_id` MUST return `log_not_found`; a read MUST NOT create a log | `Store.frontier(unknown)` returns **`{:ok, %{writers: []}}`** and creates **six files** — the database, its WAL/SHM, the lock database and journal, **and a durable `.writer` identity sidecar**. A read mints and persists an append-lane identity for a log nobody created. |
| V2 | §5.12: ordinary activation MUST refuse a log with more than one writer lane | Two lanes were appended into one log and **nothing refused at any layer**; the frontier simply reports two writers. |
| V3 | §6: the ordinary public API MUST NOT invite callers to select an append lane | `LogStore.append/4` still takes `writer_id` in its signature. **Our implementation silently ignores it** and uses the Server's identity — so the parameter is not merely unnecessary, it is *misleading*: a caller passing one reasonably believes it took effect. A signature that lies is worse than either honest option. |
| V4 | §7 / §17.2.5: rekeying an ordinary Document log is prohibited | `Server.rekey/1` exists and is callable, and its own test asserts it starts a second lane in the same log. |

**Already satisfied (keep, and keep tested):** one `writer_id` retained across restart; replica sync cannot cross `log_id` values (`log_mismatch`); replica-local arrival order is non-semantic (§18.11); the Engine/Persistence split, `Sync`, the SQLite adapter, the DO workalike and the whole conformance corpus — the profile's entire §17.1 Preserve list.

**Not yet present:** fencing epochs and leases (§4.3, §13); the `DocumentProfile` façade (§17.2.1); a lineage interface (§17.2.7); CI (§17.2.10).

## 2. DECIDED — fencing epoch is authoritative (jes, 2026-08-23)

**Accepted:** the fencing epoch becomes the authoritative exclusivity mechanism, reusing the
compare-and-swap plumbing the persistence contract already has; the SQLite file lock is retained
as a cheap local early-out where it genuinely applies. Task 3 is unblocked.

**The reason this had to change, recorded because the availability argument is the weaker one
and a later reader will otherwise reconstruct the wrong motivation:**

The file lock is scoped to **a filesystem**; the log, in the sidecar deployment, is scoped to
**the Durable Object**. Those scopes stop matching in SP4, and when they do not match the lock
supplies no exclusion while still reporting success. Two Realm Containers each hold their own
ephemeral disk: both create and lock `<log>.lock.sqlite3` locally, both succeed, neither can see
the other, and both append to the same lane through the shared sidecar — which is exactly the
two-live-appenders fork this profile exists to forbid. ⇒ **The lock is load-bearing today and
becomes decorative in SP4, in the way that is hardest to notice: it still returns success.**

Secondary: §13 is titled *migration* and failover, in that order. Containers are replaced on
rollout, slept on idle and woken elsewhere, so handoff is an ordinary lifecycle event. A
mechanism requiring the outgoing holder's cooperation makes every routine rollout contingent on
clean shutdown.

**What fencing does NOT cost, stated precisely because I first overstated it:** acknowledgement
follows durable commit (invariant 2), so an overridden activation's commits fail at the epoch
check and were never acknowledged, while commits it made legitimately before the CAS stand.
**No acknowledged write is at risk.** What is lost is accepted-but-uncommitted work — exactly
what a crash loses.

Fencing does not repeal §13's rule that a system unable to establish exclusive continuation must
stop or derive a new lineage log. It makes exclusivity *establishable* where waiting cannot.

## 2b. Original framing (superseded, kept for the reasoning)

**Our cross-process lock and the profile's fenced lease solve overlapping but different problems, and the difference matters for failover.**

Today, exclusivity comes from a SQLite `BEGIN EXCLUSIVE` held for a Server's lifetime. That gives genuine mutual exclusion and releases automatically if the holder dies (measured). But it is **not preemptible**: a new activation cannot take the lane while the old process is *alive but unreachable* — it can only wait for the holder to die or release.

The profile's model (§4.3, §13) is a monotonically increasing **fencing epoch** verified at every commit: placement advances the epoch by CAS, the destination activates on the new epoch, and the old activation — even if still running — **fails at commit** because its epoch is obsolete. That is what makes §13's handoff work when the source Realm is wedged rather than dead.

⇒ These compose rather than conflict: the lock prevents two live *local* processes, the epoch makes an obsolete activation harmless anywhere. **My recommendation is to implement the epoch as the authoritative fence and keep the lock as a local convenience**, because a handoff that requires the old holder's cooperation is not a fence. But the profile is jes's and this is a change in failover semantics, so I want it confirmed rather than assumed. It is also the one place where the profile's §13 cannot be satisfied by what we already have.

## 3. Tasks

### Task 1: Reads must not create logs (fixes V1)
- [ ] Red-first: reading `frontier`/`read_writer`/`tail_local`/open on an unknown `log_id` returns `log_not_found`, and **the data directory is unchanged afterwards** — assert the file listing, since the durable side effect is the actual defect. Include the writer sidecar explicitly: no identity may be minted by a read.
- [ ] Separate "open existing" from "create": `create_log` remains the only path that may write. Reads resolve an existing store or fail.
- [ ] Keep `create_log` idempotent, and keep it persisting the durable `writer_id` before acknowledging (§7).
- [ ] Commit: `fix(elixir): reads never create a log or mint an identity`

### Task 2: Single-lane invariant (fixes V2)
- [ ] Red-first: a log holding two writer lanes is **refused for ordinary activation** with `multiwriter_document_unsupported` (§16). The check belongs where a Document opens a log, not in the persistence adapter — adapters must not gain domain opinions.
- [ ] An append that would introduce a second lane into an ordinary log is refused before it commits.
- [ ] The base protocol keeps its multi-writer capability: `Engine`/`MergePlan`/`Sync` are unchanged, and the existing multi-writer conformance and property tests must stay green. §15 is explicit that multi-writer remains a protocol capability; this is a *profile* restriction.
- [ ] Commit: `feat(elixir): refuse multi-lane logs for ordinary Document activation`

### Task 3: Handle-and-lease append API (fixes V3, V4) — **after jes answers §2**
- [ ] `Commonplace.Log.DocumentProfile` façade per §6: `create_log/2`, `open_log/2` taking a lease, `append/3` taking a handle. The handle binds `log_id`, the durable `writer_id`, the lease epoch, the adapter and store, and idempotency context. **Callers never see `writer_id`.**
- [ ] Fencing epoch verified at every commit (§13), such that an obsolete lease cannot commit even while its process lives.
- [ ] Accept a caller-supplied idempotency key (§6, SHOULD) so an ambiguous transport failure can be retried without a second logical effect.
- [ ] Remove or restrict `rekey/1` for ordinary Document logs; recovery derives a **new lineage log**, never a second lane in the old one (§7).
- [ ] Keep `Engine.append` with explicit `writer_id` as an internal protocol operation, documented as such (§17.2.3).
- [ ] Errors per §16: `writer_lease_unavailable`, `writer_lease_fenced`.
- [ ] Commit: `feat(elixir): fenced document-profile append surface`

### Task 4: Naming and documentation (§17.2.6, .8, .9)
- [ ] Rename in documentation — not necessarily in code — so `Commonplace.Log.Sync` is unambiguously **replica** synchronization, and state what it must never do (§8's prohibition list is precise and worth quoting).
- [ ] Topology docs place Document processes beneath Cell activation; the Realm sidecar is described as physical persistence, never logical authority (§14).
- [ ] Commit: `docs: name replica synchronization and Cell-owned topology`

### Task 5: CI (§17.2.10)
- [ ] Run Elixir suite, TypeScript suite, `conformance/check.sh` and a bounded `fuzz.sh` on push. Note the Elixir suite is ~70s because of the property tests.
- [ ] Commit: `ci: run both suites, shared vectors, and differential checks`

**Deferred by the profile itself, not by me:** lineage records and the Document/Cell lineage-sync interface (§9, §17.2.7) need Document and Cell layers that do not exist in this repo yet. Branches and offline mirrors (§10, §11) are lineage consumers and follow them. I would rather build the log-side invariants first and let lineage land where Cells live.

## 4. Exit criteria

The profile's §18, restricted to what this repo can demonstrate: application code appends without knowing `writer_id`; a Realm replacement cannot create a second lane in an ordinary log; a read of a missing UUID returns `log_not_found` and leaves the data directory untouched; ordinary activation refuses a multi-lane log; `Sync` is described only as replica synchronization; and every §17.1 Preserve item is still green — the multi-writer machinery included, since restricting the profile must not remove the capability.
