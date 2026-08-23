# SP4: Cloudflare Realm Sidecar — Task Plan

> **For agentic workers:** implementation goes to Sol. Steps use checkbox (`- [ ]`) syntax.

**Source:** `docs/proposals/2026-08-22-beam-native-revision.md` §§6–9 (normative), the SP4 row of
`docs/superpowers/plans/2026-08-21-commonplace-log-v0.1.md`, and the deferrals recorded in SP2/SP3.

**Goal:** A realm-scoped Durable Object that holds many logs and serves read-set/commit over an
internal HTTP boundary, plus `Commonplace.Log.Persistence.CloudflareSidecar` — such that the same
Engine behaviour is green over `LocalSQLite` **and** the sidecar.

**Acceptance (from the v0.1 ledger):** same Engine tests green over both adapters; deployment
conformance per proposal §12.

---

## 0. CURRENT STATE (updated 2026-08-23 ~04:10 — read this first)

**Landed on main:**
- Task 1 `4ea6e4e` — realm store: §7.2 schema on real DO SQLite, revision + epoch CAS, three read
  paths, and the §9 semantic-boundary gate. **worker: 235 tests** (218 pre-existing + 17).

**Two results from Task 1 worth not re-deriving:**
- **Real DO SQLite accepted §7.2 unchanged** — `STRICT`, `AUTOINCREMENT`, both indexes, every
  declared type. §7.2 called its DDL illustrative pending exactly this check; it is now checked.
  Byte identity is pinned by a test that reads the proposal itself, so drift fails a build.
- Observed workerd trigger errors, verbatim: `entries are immutable: SQLITE_CONSTRAINT` (UPDATE
  and DELETE) and `entry is too large: SQLITE_CONSTRAINT`. The exqlite surface says only
  `entries are immutable` — **the suffix differs by runtime**, so assert what you observe.

**In flight:** Task 2 (sidecar HTTP contract) dispatched to Sol detached,
`scratchpad/sol-sp4-task2.log`.

**Operational note — the launch receipt.** Detached rounds survive the harness reaper but there is
no report if one dies at exec, and a dead round looks exactly like a quiet one. A quiescence
monitor cannot tell them apart either: **it proves the instrument can fire, not that it has a
subject.** Confirm a dispatch by *process exists OR log growing, measured over at least 60s* —
a 20s window false-alarms on Sol's initial read-and-think phase.

---

## 0b. Original state (2026-08-23, plan written)

SP-DP complete and CI-green (run 32615109259). Baseline on `main` @ `fb59f25`:

    commonplace_log:  195 tests + 5 properties, ~78s      worker: 218 tests
    conformance/check.sh GREEN                            CI: 5 checks, green

**Measured before writing this plan — use these, do not re-derive:**

| Fact | Measurement |
|---|---|
| `wrangler dev --remote` | `[boolean] [default: false]` — local is the default |
| wrangler version | 4.125.0, already installed under `worker/` |
| Elixir HTTP client | **none in `mix.exs`** (`jason`, `exqlite`, `stream_data` only); OTP's `:httpc` is available without a new dep |
| Node | v24.13.1 |

---

## 1. The split, and why it is not arbitrary

SP4 divides on a hard capability line, not on convenience:

- **SP4a — locally verifiable.** The realm DO, the sidecar HTTP contract, the Elixir adapter, and
  the shared persistence suite. All of this runs under the vitest workers pool and `wrangler dev`
  in local mode, exactly as SP2 did.
- **SP4b — requires jes.** A Cloudflare account, **Containers** access, real deployment, and the
  genuine `idFromName` end-to-end path. Containers run BEAM; there is no local workerd equivalent,
  so nothing in 4b can be honestly asserted from this box.

⭐ **The point of the split is that 4a's claims stay checkable.** SP2 taught this the expensive
way: `ctx.id.name` is always `undefined` under the workers pool, so named addressing could not be
verified there and was deferred. Put every unverifiable claim in 4b and *say so in the report*
rather than letting a green local suite imply a deployment works.

**Do not start 4b speculatively.** Ask jes when 4a is done.

---

## 2. The structural constraint that will be violated if it is not mechanized

Proposal §9 is explicit and load-bearing:

> The new sidecar must not import entry canonicalization or merge-classification modules.

The sidecar is **log-shaped storage**. It stores rows and does compare-and-swap. It does not know
how rows become a valid history. The SP2 workalike DO — which *does* canonicalize and classify —
sits right next to it in the same tree, and reusing `merge-plan.ts` or `entry.ts` would look like
sensible deduplication while quietly making the storage boundary semantic.

⚠️ That is the same failure the proposal names elsewhere as "the sidecar boundary becomes secretly
semantic," and SP3 already applied it to the *local* adapter. It applies here far more sharply,
because here the boundary is a network.

⭐ **A remembered rule does not fire; a filed artifact does.** So this gets a mechanical gate:
a test that walks the realm-sidecar source's import graph and fails if it reaches `entry.ts`,
`jcs.ts`, or `merge-plan.ts`. Demonstrate it red (add the import, watch it fail, remove it) before
trusting it green.

**Also preserved:** the SP2 workalike DO (`worker/src/do/*`) is frozen as a milestone. SP4 adds a
sibling; it does not edit the workalike.

---

## 3. The correctness problem SP4 must solve, recorded in SP3

From the SP3 plan, verbatim in substance:

> `Engine.append` mints a fresh `entry_id` on each stale-revision retry. Measured harmless today
> … But the sidecar introduces a genuinely ambiguous outcome — **a lost acknowledgement is not a
> stale revision.**

Locally, a commit either applied or did not, and the Engine only retries on an explicit
`:stale_revision`. Over a network, a timeout means *unknown*. Retrying an unknown with a freshly
minted `entry_id` can write the same logical append twice under two identities.

⇒ **`commit/2` over the sidecar must be idempotent, or the adapter must detect its own prior
success by re-reading, before any retry widens beyond `:stale_revision`.** This is Task 4 and it
is the highest-risk item in SP4. It must be tested against a transport that actually loses
acknowledgements, not one that merely returns errors.

---

## 4. The fencing epoch is why this deployment is safe

SP-DP Task 3′ made the epoch authoritative and the file lock a local early-out, *specifically*
anticipating this deployment: two Realm Containers each with their own disposable disk would each
lock their own local file, both succeed, and neither see the other.

⇒ **The sidecar adapter must implement the epoch, and here the epoch's CAS is the only real
exclusivity that exists.** There is no shared filesystem to fall back on. An adapter that
implements `commit` but stubs the epoch would pass a naive suite while removing the single
mechanism preventing two appenders on one lane.

The shared persistence suite (Task 5) must therefore cover the epoch explicitly, and must be
demonstrated to fail against an adapter whose epoch check is removed.

---

## 5. Tasks

Each task: red first, gates demonstrated able to fire, no failure-swallowing, report into
`SOL_REPORT.md` as it goes. Adversarial verification is part of each brief, not a review
afterthought — every gate must be watched failing before its green is believed, and any sabotage
introduced to force a red must be confirmed to have actually applied.

### Task 1 — Realm schema and store (`worker/src/realm/`)

- [ ] The §7.2 realm DDL: `logs`, `entries`, `writer_tips`, both indexes, `STRICT` throughout.
      Retain the immutability triggers and entry-size checks the current schema carries — §7.2
      calls the DDL illustrative *until reviewed against Cloudflare's supported SQLite subset*, so
      **run it against real DO SQLite and report any rejection rather than adjusting it silently.**
- [ ] Per-log `revision` and lease `epoch` columns on `logs`, with the same discipline the local
      adapter uses.
- [ ] Multi-log isolation is the new property here and must be tested directly: two logs in one
      realm DB, and operations on one must not observe or disturb the other. A `log_id`-scoping
      bug is invisible in every single-log test.
- [ ] Red arm: drop a `log_id` predicate from one query, watch isolation fail, restore.

### Task 2 — Sidecar HTTP contract (`/read-set`, `/commit`)

- [ ] Exactly the two batched round trips of §6. ⛔ No route that is a remote analogue of a single
      `step/2` — §8.2 forbids it, and the DO and Container are not guaranteed to be colocated.
- [ ] Request/response shapes carry the ReadSet and CommitPlan of §6.1/§6.2 **including
      `expected_revision`, the epoch, `prev_entry_id` and `created_at`** — the omission that caused
      the SP3 Task 4a defect, where the adapter wrote NULL and `1970-01-01T00:00:00Z`.
- [ ] Storage errors only: `:stale_revision`, epoch mismatch, constraint, `storage_full`. **No
      domain error may originate here** (`writer_gap`, `writer_fork`, `entry_id_collision` are the
      Engine's). Assert this negatively: a fork-shaped commit returns a storage constraint failure
      from the sidecar, and the *Engine* names it.
- [ ] The import-graph gate from §2, demonstrated red.
- [ ] `storage_full` — SP2 could not simulate it and pinned only its spelling. Try to simulate it
      here; if it remains unsimulable, say so plainly and keep the spelling pinned.

### Task 3 — `Commonplace.Log.Persistence.CloudflareSidecar`

- [ ] Implements the full behaviour including the epoch callbacks. Adapter returns **storage facts
      only**; profile/domain names originate above it, as SP-DP established.
- [ ] **Transport is injectable.** A behaviour for the HTTP call, with the real one over `:httpc`
      (zero new deps) and a test double. This is what makes Task 4 testable at all, and it keeps
      the adapter unit-testable without wrangler. If a pooled client later proves necessary,
      measure first and record the measurement.
- [ ] The Elixir release stays Cloudflare-ignorant (v0.1 ledger, §8.2): the adapter talks to a URL
      and knows nothing of DOs, `containerId`, or realm resolution.

### Task 4 — Lost acknowledgements (see §3 above)

- [ ] Make `commit/2` idempotent across the sidecar, **or** have the adapter re-read and detect its
      own prior success. Choose one and record why.
- [ ] Test with a transport double that **loses the acknowledgement after the commit applied** —
      not one that fails before it. Those two are different scenarios and only the first is the
      dangerous one; a suite testing only the second would pass while the bug remains.
- [ ] Assert the logical effect happened **exactly once**: one entry, one `entry_id`, one sequence.
- [ ] Red arm: disable the idempotency mechanism, watch the double-write appear, restore. ⭐ This is
      the single most important red arm in SP4 — if this gate has never been seen to fail, the
      mechanism is not known to work.

### Task 5 — The shared persistence suite (the acceptance criterion)

- [ ] One suite, parameterized over both adapters, covering: create, read-set, commit, stale
      revision, epoch fencing, idempotent/lost-ack commit, `frontier`, `read_writer`, `tail_local`,
      continuation cursors, and the read-never-creates guarantee from SP-DP V1.
- [ ] It must extend, not replace, the existing cross-adapter equivalence test — that test exists
      to catch adapter drift and has already caught a real shape divergence (SP3 Task 8).
- [ ] **Anti-vacuity, mandatory:** demonstrate the suite fails against a deliberately broken
      adapter — one with the epoch check removed, and one with `expected_revision` ignored. A
      cross-adapter suite that passes against a broken adapter is proving nothing, and this is the
      artifact the whole sub-project is judged on.
- [ ] Report the case count and confirm both adapters actually ran. ⭐ An adapter that was skipped
      and an adapter that passed look identical in a green summary.

### Task 6 — `wrangler dev` integration, local

- [ ] Elixir against a real `wrangler dev` (local; `--remote` is off by default). This is the first
      point where both runtimes meet over a real socket rather than a double.
- [ ] Positive control before believing any pass: confirm the request actually reached wrangler
      (its log, or a deliberate 4xx), because "connected and passed" and "silently talked to
      nothing" otherwise look the same.
- [ ] Not in CI initially — record the runtime and flakiness first, then decide. A flaky required
      check trains people to ignore red.

### Task 7 — SP4b readiness note (no deployment)

- [ ] Write down exactly what jes must supply: account, Containers access, realm naming, the
      gateway Worker's auth (401/403 are gateway-side per SP2), and the `storage.internal` outbound
      handler's realm derivation from `containerId`.
- [ ] State the security property that only 4b can verify: **the BEAM request cannot select another
      client's realm.** §8.2 makes the outbound handler responsible; that is a claim about deployed
      configuration and must not be asserted from a local run.
- [ ] List every claim SP4a could not verify. That list is the deliverable.

---

## 6. Preserve — do not modify

- `docs/commonplace-monotonic-log-spec.md` — byte-identical, always.
- §2/§3 exclusions stay excluded: no Merkle trees, CRDTs, total order, consensus, deletion or
  compaction, signatures. They are decisions, not gaps.
- `worker/src/do/*` — the SP2 workalike, frozen. SP4 adds a sibling.
- `conformance/` — a **cross-repo surface**; byte-rule, numbering, or `expected.hex` changes must
  be announced to `commonplace-log-reducer`. Adding vectors is safe.
- `Engine`, `MergePlan`, `Sync` semantics — the sidecar rides the existing commit path.
- The Document Profile's single-lane, no-`writer_id`, no-rekey façade surface.

## 7. Open question for jes

Task 7 is where SP4a stops. **Whether to proceed into 4b — real Cloudflare deployment — is jes's
call**, and it needs account and Containers logistics that were explicitly deferred at 23:10Z on
2026-08-21 "until SP4". Ask; do not assume.
