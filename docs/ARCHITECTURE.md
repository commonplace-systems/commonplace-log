# Commonplace-Log Architecture — current and planned

**Status (measured at `1899704`, 2026-09-14).** Everything in §§1–8 describes code on `main` at
that commit and is stated from reading it. Claims about the *live* deployment are marked as such:
this document records the deploy **mechanism**; live state belongs to readbacks at deploy time,
not to a document that goes stale the moment the next deploy runs. Coordination facts (current
production version id, in-flight rounds) are cited to their channel records where used.

This document complements, and does not replace: [`README.md`](../README.md) (the protocol in
brief and how to run the checks), [`commonplace-monotonic-log-spec.md`](commonplace-monotonic-log-spec.md)
(the normative protocol, amended in [`protocol/`](protocol/)), and
[`sp4b-deployment-readiness.md`](sp4b-deployment-readiness.md) (what has and has not been
verified against the real platform). Where those documents own a topic, this one points at them.

---

## 1. What this system is

An append-only log that several parties can write to, replicate, and merge without a leader,
consensus, or a CRDT. One rule carries the design: **every writer owns its own gapless sequence
1, 2, 3…, and a log is the union of those sequences.** Merging keeps the longer per-writer
prefix; a *different* entry at the same `(writer_id, writer_seq)` coordinate is a `writer_fork`
— the log refuses and stops, because either choice would discard someone's data while looking
like success.

This repository is the **log layer** of a larger stack (`log → reducers → commonplace-doc →
directory → cell`, per the 2026-08-23 layering ruling in the readiness doc §4a). A *realm* is
physical containment — one realm database holds many UUID-addressed logs — and never logical
authority over them. The sibling repositories (`commonplace-next`, `commonplace-doc`,
`commonplace-log-reducer`) build on the surfaces described here; `conformance/` is a
cross-repository contract they consume.

## 2. The system at a glance

```
  app (commonplace-next)                    operator / backup
        │ HTTPS, bearer                            │
        ▼                                          ▼
 ┌─────────────────────────────┐        ┌──────────────────────────┐
 │  gateway Worker             │        │  backup Worker           │
 │  worker/src/index.ts        │        │  worker/backup/ (separate│
 │  deploy token → create/     │        │  script; read caps only) │
 │  allocate; else pass-through│        └───────┬─────────┬────────┘
 └───────────┬─────────────────┘             KV │         │ R2
             │ idFromName(realm_id)     REALM_REGISTRY   backup
             ▼                          (realm → read     bucket
 ┌───────────────────────────────────┐   capability)
 │  RealmNode — one DO per realm     │◄───────┘  (script_name DO binding)
 │  worker/src/realm/*               │
 │  • bearer auth (hashes only)      │
 │  • realm SQLite: many logs        │
 │  • lease epochs, restore markers  │
 │  • manages the BEAM container     │
 └───────┬───────────────▲───────────┘
         │ boots         │ http://storage.internal
         ▼               │ (outbound handler derives the realm
 ┌───────────────────────┴───────┐   from platform containerId —
 │  Cloudflare Container: BEAM   │   nothing the engine sends can
 │  commonplace_log/ Elixir node │   select another realm's storage)
 │  Engine / DocumentProfile /   │
 │  Persistence.CloudflareSidecar│
 └───────────────────────────────┘
```

Two implementations of the protocol exist on purpose (§4); the Elixir one is normative and also
runs *inside* the deployment as the engine in the container.

## 3. The spec core (normative, Elixir — `commonplace_log/`)

Amendment 1 makes the Elixir library normative: where prose and behaviour disagree, the
behaviour wins and the spec is amended.

- **`Entry`** — validates the eight-field entry (v1) and the nine-field v2, which adds a
  required `operation_id`: the caller's idempotence key, opaque to the log (Amendment 2).
  Entries are I-JSON, canonically encoded (RFC 8785 / JCS), capped at 1 MiB canonical bytes.
- **`Jcs`** — the canonicalizer. Every runtime must agree on the exact bytes of every entry;
  this is what makes cross-runtime byte equality checkable at all.
- **`MergePlan`** — pure, side-effect-free merge classification: for each writer, extend /
  no-op / `writer_gap` / `writer_fork` / `entry_id_collision`. Domain classifications originate
  *only* here and in `Entry`; a storage layer that emits them is non-conforming (Amendment 1 §3).
- **`Engine`** — the domain decision-maker over the persistence contract: coherent read set →
  declarative commit plan → atomic commit under `expected_revision` CAS, with the lease epoch
  re-verified **inside** the commit transaction (checked-then-merged was observed racing; see
  README "things that look like oversights").
- **`Frontier` / `Sync`** — per-writer tips, and frontier-driven range synchronization between
  two stores.
- **`Persistence`** — the storage boundary, with three interchangeable adapters proven
  equivalent by one suite (and proven falsifiable by deliberately broken adapters):
  in-memory, **`LocalSQLite`** (one file per log), and **`CloudflareSidecar`** (HTTP to a realm
  DO, over an injectable transport whose default is `:httpc`).
- **`LogStore.SQLite`** — the local multi-writer store: per-log server process found or started
  by `Registry` + `DynamicSupervisor` (`server_for/2`), an exclusive lock file, and a durable
  writer identity so an ordinary restart keeps its identity and a cloned disk is forced to take
  a new one.
- **`DocumentProfile`** — the single-lane document surface, and the **exact-retry** path:
  `prepare_append/3` derives entry ids deterministically from `operation_id` + caller-supplied
  `created_at` + current state, so a caller that crashes between prepare and learning its
  commit's fate can re-prepare byte-identical entries. A displaced activation gets
  `writer_lease_fenced`, deliberately distinct from `writer_fork`.
- **`RealmNode` (Elixir)** — the HTTP node that runs inside the container: engine and document
  routes, reaching storage only through the configured base URL (`storage.internal` when
  deployed).

Errors everywhere have the shape `{:error, {code, details}}`, with protocol codes
(`writer_gap`, `writer_fork`, `invalid_entry`, …) distinct from `:storage` failures.

## 4. The TypeScript workalike and the conformance surface (`worker/src/do/`, `conformance/`)

`worker/src/do/` is an independent, conforming per-log Durable Object: its own validator,
canonicalizer, and merge classifier, sharing no code with Elixir, frozen as the SP2 milestone.
An import-graph test enforces that the realm surface (§5) never borrows its canonicalization or
merge code — the semantic boundary is mechanical, not conventional.

`conformance/` holds language-neutral vectors: canonical-JSON cases with expected bytes, and
invalid-entry cases fixing an error code and reason slug both runtimes must produce.
`check.sh` compares the runtimes with each other and with stored expectations (one vector is
deliberately wrong so the harness must observe its own expected failure before reporting
green); `fuzz.sh` runs seeded differential fuzzing. The point of the second implementation is
that the protocol cannot be accidentally defined by Elixir internals.

## 5. The realm surface — the deployed provider (`worker/src/index.ts`, `worker/src/realm/`)

One **gateway Worker** and one **`RealmNode` Durable Object per realm**. The DO is three things
at once: the realm's bearer-auth boundary, the realm's SQLite (many logs in one database,
proposal §7.2 schema with immutability triggers and the 1 MiB entry trigger), and the manager
of the realm's BEAM container.

**Authorization** (ruled 2026-08-25; REALMAUTH-R4):

| Credential | Grants exactly |
| --- | --- |
| deployment token (`GATEWAY_TOKEN`) | `POST /realms/{uuid}` (create) and `POST /realms/{uuid}/allocate` — nothing else |
| realm write secret (returned once at create/allocate; only its SHA-256 stored) | every route in that realm: sidecar, engine, node lifecycle, restore wire |
| realm read capability (minted under the write secret, or derived at allocation) | exactly the read routes: `/list-logs`, `/list-log-ids`, `/frontier`, `/read-set`, `/read-writer`, `/tail-local` |

A gateway with no secret configured answers 503 to everything but `GET /` — it fails closed.
Comparisons are constant-time; secrets never appear in responses after the one-time return.

**Container lifecycle.** `RealmNode` boots the BEAM image on demand; the engine reaches storage
only via `http://storage.internal`, which the Worker-side outbound handler resolves from the
**platform-supplied** `containerId` — the request carries nothing that participates, which is
the deployed form of cross-realm isolation (readiness doc §3, verified with two realms). A
container is one restartable *incarnation*; logs outlive it. Writes from a superseded
activation are fenced by the lease epoch **at commit**, verified against a real container
(readiness doc §4b, the rollout-overlap experiment). Capacity exhaustion maps to
`503 realm_capacity` — a mapping the platform itself has produced once, which is the repo's bar
for calling a mapping a behaviour.

**Registry.** Realm creation registers the realm in the `REALM_REGISTRY` KV namespace (realm id
→ read capability), refusing creation with 503 rather than minting an unregistered realm —
because realms **cannot be enumerated from the platform** (`idFromName` is one-way; the DO
listing has ids and `hasStoredData`, no names), the registry is the only thing standing between
"backed up everything" and "backed up everything I happened to know"
([`backup-design.md`](backup-design.md) §1). The DO object *count* is the registry's control.

**Removal and reconciliation.** Realm removal wipes storage; a registry row that outlives its
realm is an orphan handled by the **reconciliation library** (`worker/reconciliation/`,
administrative, no deployed entry point): dry-run by default, absence established only by an
explicit `not_found` body, unknown never deleted, deletion double-gated behind `apply` and an
externally-quiesced lifecycle window. The honest close of its remaining race is
`REGISTRY-SELF-DELETE-1` (planner-ranked): move deletion inside the DO's lifecycle gate.

## 6. Allocation, restore, and legacy-realm safety (landed `8959df1`…`1899704`)

The newest surface, built so the app's provider can be re-provisioned and re-populated safely.

**Idempotent allocation** — `POST /realms/{id}/allocate` (deployment token). Unlike create,
the **caller supplies** the 64-hex realm secret plus an `operation_id`; the DO records only
hashes, derives the read capability deterministically from
`(realm_id, operation_id, secret)`, and writes it to the registry. The same triple replayed
answers `200 existing`; any divergence is `409 allocation_conflict`. That makes realm
provisioning safe to retry across the exact failure the log itself guards against — acting
twice because an acknowledgement was lost.

**Bounded restore wire** — `POST /list-logs` (bounded inventory with a digest `generation`) and
`POST /restore-bundle-batch` behind realm bearer auth, with explicit bounds at every layer
(64 logs, 4096 entries/log, 1 MiB/entry, 16 MiB payload, 32 MiB raw body buffered at the
gateway with a read deadline). Restore state is durable: `restore_bundles` /
`restore_bundle_logs` / `restore_markers` track per-log `pending → complete`, and
**`requireRestoreComplete` refuses ordinary reads and writes of a partially-restored log**
(`obsolete_epoch`) — a half-restored log must decline, not answer. The wire performs
*structural* checks only (UTF-8, shapes, sizes, base64 round-trip); it deliberately does not
import `src/entry.ts` — semantic validity is the restore caller's job (commonplace-next's
archive decoder refuses tampered archives before sending), and the realm's semantic boundary
(§4) stays intact. Main's paginated id listing is `/list-log-ids`; `/list-logs` is the bounded
restore inventory.

**Legacy-realm safety** (`LOG-LEGACY-REALM-FIX-1`). The 2026-09-13 beta-next outage: a realm
whose schema predates restore answered `/frontier` with a raw 500, because a read path queried
`restore_markers` unguarded. The fix's rule is now load-bearing: **a missing restore table
means "no restore state", and nothing creates schema on a read route** — a read capability must
never be able to mutate. The gate is a byte-pinned fixture of the `76f9028`-era realm code:
the test *builds a legacy realm by running the old code*, then drives every current route over
it and asserts `sqlite_master` and all rows unchanged by reads. Demonstrated red on the
unfixed commit, green after.

**Restore has two sources, at different stages.** The wire above imports bundles from the app's
own archives, and is deployed. Replay *from the R2 backup* is `BACKUP-1c` — designed, assertion
written down (per-writer replay through write routes into a fresh realm; equality of every
`entry_id`, not counts), **not yet rehearsed**. Until it is, the repo's own words apply: *a
backup nobody has restored is not a backup.*

## 7. Backup (`worker/backup/`, [`backup-design.md`](backup-design.md))

A **second Worker**, deliberately: deploying the main Worker builds and rolls out the BEAM
image (measured moving 7 live instances), so the backup's iteration cadence must not be the
storage engine's rollout cadence. The backup Worker binds the main script's `RealmNode`
namespace by `script_name`, the registry KV, and an R2 bucket; its authority is **exactly the
read routes** — it holds no write secret, so a compromised backup cannot corrupt the live
store, and restore is an operator act by construction.

The walk is registry-driven (realms cannot be discovered, §5), append-only and idempotent in
R2 (`<realm>/<log>/<writer>/<seq>.json`, frontier written *after* entries, realm manifest after
all frontiers — a run that dies mid-walk resumes rather than lying), and re-verifies chain
integrity itself instead of trusting the source; a realm whose chain misbehaves is stopped with
a named error. Derived object keys are classified **sensitive metadata** (`BACKUP-KEYS-1`
ruling: listings can confirm membership guesses and disclose document inventory — never paste
live listings anywhere), enforced by a SHA-256 review manifest over the backup source
(`worker/scripts/check-backup-output.py`) that fails on any unreviewed output path.
Activation (cron, real registry binding) is separately held; pre-registry realms are not
backfilled by the loop — that inventory starts from commonplace-next, which knows what it
created.

## 8. Deployment topology and provenance

- **One deploy, two artifacts.** `wrangler deploy` of the main Worker ships the Worker *and*
  builds the container image from `commonplace_log/`. Rollouts are staged: the Worker version
  changes immediately; containers started before the application reads `ready` still run the
  old image (measured ~6 minutes). "Deployed" is two claims with two clocks.
- **Provenance.** Deploys carry `prov:source-sha`; instruments that depend on the deployed
  surface (the backup's expectations, activation prerequisites) compare against it rather than
  assuming.
- **Deploy authority.** Provider deploys are executed by boss through a plan packet with an
  existing-state readback (the 2026-09-13 outage rule). This repository's rounds implement and
  land; they do not ship.
- **`REALM_TEST_LEVERS`.** Stripped from the production config by jes's ruling (Telegram
  11925, landed as `fecfc6b`, 2026-09-14). It is a development-only lever enabling the
  `x-commonplace-test-commit-delay-ms` header (a commit sleep up to 90 s in the Elixir
  RealmNode) and `allowUnboundRegistry` creation; tests set it in `wrangler.test.jsonc` or
  inline. `PROVIDER-DEPLOY-4` shipped the strip to production the same day (2026-09-14,
  boss-executed, `--containers-rollout=none`) — a worked example of the two clocks above:
  the Worker changed immediately, while `commonplace_log/` changes landed on main after the
  image build wait for the next container-rebuild deploy.

## 9. Known gaps and roadmap

### The 2026-09-14 audit — ranked, with dispositions

A full-repo audit (at `bb73888`, clod-squad #38024) ranked the top 10 improvements. The core
finding: the spec core (§3, §4) is clean on both runtimes — no fork/gap/canonicalization defect
found; weaknesses cluster in the newer realm surface, which has not yet inherited the standards
the do/ surface set, and in instruments that look enforced but are not.

| # | Item | Effort | Disposition (2026-09-14) |
|---|---|---|---|
| 1 | `REALM_TEST_LEVERS` shipped-by-default, comment-guarded | S | Closed: jes ruled strip (Telegram 11925), landed as `fecfc6b` (§8); reaches production on the next provider deploy |
| 2 | `RealmStore.commit` enforces no invariants; `/create-log` accepts empty log id — an authorized writer can wedge a realm's backup | M | Released to this repo, conditioned on the legacy-realm gate and app-request-shape compatibility (every new refusal needs a valid-neighbour arm) |
| 3 | Realm HTTP surface lacks the do/ surface's size/limit gates, both runtimes | M | Same release and conditions as #2 |
| 4 | CI enforces neither the TS typecheck nor any gated arm; fuzz seed fixed since 2026-08-23 | M | In flight |
| 5 | `:httpc` sidecar transport has infinite default timeouts | S | In flight |
| 6 | `log_id` path traversal into LocalSQLite at the Elixir RealmNode boundary | S | In flight |
| 7 | Document prepare path: O(n²) full-lane rescan per append; paged `read_lane` crash; server-minted `operation_id` makes exact-retry inert over HTTP | M/L | HOLD — overlaps SAVE-STALL-1 investigation |
| 8 | Benign concurrent document appends surface as `writer_fork`, diluting the halt-everything code | M | HOLD — same overlap |
| 9 | Realm DOs lack the do/ surface's §13.1 identity self-check; two stale comments describe unreachable orphan-retry behaviour | S | Released to this repo, same conditions as #2 |
| 10 | `check-backup-boundary.sh` frozen to a fixed commit — guaranteed to go red on the first legitimate change; its write-surface regex has a diverging second copy | S | In flight |

Below the cut (tracked, unranked): config drift points (`compatibility_date` duplicated across
five wrangler files; the hand-maintained tsconfig include/exclude complement), triple
canonicalization on the do/ merge path, the sidecar's error parsing rejecting any extra field,
5 s default GenServer call timeouts leaving committed-but-reported-failed writes ambiguous,
undeclared harness dependencies (`python3`, `xxd`, Node ≥ 23).

### Already-tracked elsewhere

- **`BACKUP-1c`** — restore rehearsal from R2, the backup arc's exit condition (§6, §7).
- **`REGISTRY-SELF-DELETE-1`** — registry cleanup inside the DO's lifecycle gate (§5).
- **`ORIGIN-ACTIVE-AUTHOR-1`** — bounded active-author call diagnostics; designed
  (2026-09-08 proposal), implementation HOLD pending Next and Plan review.
- **SAVE-STALL-1** — a stall reproduction under investigation in commonplace-next; may land on
  the document commit/sync path this repo serves (why audit items 7 and 8 are held).

### Platform-blocked (readiness doc §4/§4b — unchanged)

`storage_full` has **never executed anywhere** (workerd refuses the pragma that would induce
it; the 507 mapping is a spelling until the platform produces the shape once).
Container↔DO latency under real placement is unmeasured. Real network failure under production
scheduling is unexercised (lost-acknowledgement behaviour is verified through the transport
seam only). Two live incarnations of one realm was closed as *unreachable by construction* —
a rollout does not preempt a running DO-managed container — with the fence verified against
the reachable superseded-activation case. Sharding (§7.3 placement directory) is designed,
not built, and waits on need.

## 10. What must not change

The readiness doc §6 list is a set of decisions, not gaps: no Merkle trees, CRDTs, total
order, consensus, deletion/compaction, or signatures in 0.1. The spec file stays
byte-identical; changes are amendments. `conformance/` is a cross-repository surface — byte
rules, numbering, and `expected.hex` change only with announcement to the sibling repos;
adding vectors is safe. The SP2 workalike under `worker/src/do/` is frozen. `Engine`,
`MergePlan`, and `Sync` semantics stay as they are. And the boundary that §6 added is now on
the list: **nothing creates schema on a read route.**
