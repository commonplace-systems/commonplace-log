# Response to ruling 2 — exact retry and prepared append

**Status:** design response. ⛔ **Not authorised to implement.** jes labelled the source document
"Proposed design rulings"; this reads design as settled and implementation as a separate decision.

**Source:** `commonplace-doc/docs/proposals/2026-08-23-open-questions-rulings.md` (`d3b509d`,
sha256 `4d9d75b78d08fed1…`), §2 "Torn writes and exact retry" and §3 "Prebuilt entry admission".

---

## 1. The ruling is satisfiable mostly by composition, not new mechanism

The required semantics of `commit_prepared/2` already exist in `Commonplace.Log.Engine.merge/4`,
which takes fully-formed entries:

| Ruling requirement | Existing behaviour |
|---|---|
| Entries already present identically are successful no-ops | §9.3 rule 2 — byte-equal duplicate at an occupied coordinate is counted `present` (`merge_plan.ex:243-249`) |
| A different entry at an occupied coordinate is a writer-fork error | same branch — `stored_bytes != entry.canonical_bytes` → `:writer_fork` |
| Retrying the same prepared operation replays the same entries | holds automatically once entries are constructed once and kept |
| Atomic batch commitment | one `merge` produces one `CommitPlan` committed in a single transaction |

⇒ **What is missing is not the commit semantics. It is a writer-owned way to CONSTRUCT entries
without exposing `writer_id`.** `Engine.append/6` mints `entry_id` via `UUID.uuidv7()` inside
`build_append_entry` (`engine.ex:118`), which is precisely why the append path cannot be retried —
the identity is generated after the caller has lost control of it.

**So `prepare_append` is the missing half, and `commit_prepared` is a thin façade over `merge`.**
That is a much smaller change than the five bullet points suggest, and it does not need a new
Engine commit path.

## 2. ⭐ It composes with Task 4 exactly

Task 4 (`73caa5f`) resolves an ambiguous commit by re-reading and asking *"are my submitted
`entry_id`s present?"* — it cannot ask whether the log advanced, because another writer may have
advanced it.

⇒ With prepared entries that check becomes **exact rather than inferential**: the caller holds the
entry IDs, so the ambiguity is resolved by identity, not by heuristic. The ruling's clause *"an
ambiguous response never licenses the caller to prepare a replacement operation with new identity"*
is the caller-side statement of the invariant Task 4 already enforces adapter-side.

⭐ **Worth recording as corroboration, because it is the kind that counts.** These were derived
independently and from opposite ends of the same wire — Task 4 from the adapter, reasoning about a
lost acknowledgement; the ruling from the caller, reasoning about a torn write. Neither consulted
the other, and they produced the same invariant. ⚠️ Contrast the failure mode catalogued elsewhere
tonight: two parties agreeing because one relayed the other's single measurement, which reads as
confirmation while licensing trust it has not earned. **Independent derivation from different
vantage points is evidence; a repeated report is not.**

## 3. ⚠️ Two design problems the ruling does not settle

### 3.1 A prepared operation can go stale, and the epoch is why

`prepare_append` must fix `writer_seq` and `prev_entry_id` at prepare time. Those are properties of
the lane's tip. If the tip moves between prepare and commit, the prepared entry is no longer valid
and commits as a gap or a fork.

Under the Document profile a single lane has one appender, so the tip should not move underneath a
holder — **except across a fencing handoff**, which SP-DP made an ordinary lifecycle event
(rollout, sleep-and-wake-elsewhere).

⇒ **A prepared operation should carry the epoch it was prepared under, and `commit_prepared` should
reject one prepared under an obsolete epoch** — with `writer_lease_fenced`, not with a fork. A
displaced appender's stale prepared operation is not a competing account of history; it is a
message from a writer that has already lost the lane, and conflating the two would report a data
integrity error for an ordinary failover.

### 3.2 "Repeating an `operation_id` with different bodies is an error" — how much detection?

If entry identity is **derived deterministically** from `(operation_id, bodies, coordinate,
prev_entry_id)`, then reusing an `operation_id` with different bodies at an *occupied* coordinate
produces different canonical bytes and is already a `writer_fork`. ⇒ **The dangerous case is
covered with no durable state.**

⛔ But the case where the first attempt never landed is **undetectable without a durable
`operation_id` registry**, because nothing was written to conflict with. And the entry shape cannot
carry the `operation_id` itself: it is a closed eight-field object and
`extra_top_level_field` is a validation error, so the id could only live inside `body` — which is
application data the log must not interpret.

⇒ **Decision needed:** accept detection only where a conflicting entry exists (no new storage, the
error surfaces as `writer_fork`), or add a durable operation registry beside `persistence_meta`
(exact detection, a distinct error, and a new thing to garbage-collect). ⭐ I lean to the first: it
catches every case that can corrupt history, and the second adds durable state whose retention
policy nobody has asked for. **But this is jes's call, not mine.**

⭐ Deterministic derivation is possible because **`entry_id` is shape-checked only** —
`entry.ex:96` is `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`, with no version
nibble, variant, or time-ordering requirement, and nothing in `lib/` compares or sorts on
`entry_id`. Independently confirmed by execution against constructed inputs by a second party.

## 4. §3's scoping ruling closes an open thread in this repo's favour

> Raw `Commonplace.Log.merge` remains the operation for physical replicas of the same logical log.
> … Source writer IDs and source writer coordinates never become destination writer authority.

⇒ **This rules out the direction three agents had converged on** — exposing `writer_id` at the
Document façade so a cross-Document sync could hand over pre-built entries. The requirement is
removed rather than the door granted: the destination **authors its own** entries, and prepared
append is what makes that reliable.

⭐ It also preserves profile invariant 5 (no writer exposure) intact, which the alternative would
have broken. The façade surface stays `create_log/2`, `open_log/2`, `append/3` plus whatever
prepared/batch form is added — still with no `writer_id` in any signature.

## 5. What this would touch, if authorised

- **New:** `prepare_append/3`, `commit_prepared/2`, `append_batch/3` on the Document surface.
- **Reused unchanged:** `Engine.merge/4`, `MergePlan`, the persistence contract, Task 4's
  ambiguity resolution.
- **Not needed:** a new Engine commit path, an entry-format change, a schema migration.
- **Conformance:** the shared persistence contract suite (`a8752e4`) would gain retry cases; the
  §18 suite is unaffected.
- ⚠️ **`Engine.append/6` stays as-is** — it is base protocol and the ruling constrains the
  *Document* surface. Whether the non-retryable form should remain callable there is a separate
  question worth asking rather than assuming.
