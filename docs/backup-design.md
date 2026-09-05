# `BACKUP-1` — design: an append-only R2 backup walked under the read capability

**Status:** `BACKUP-1a` deliverable (commonplace-plan row 845). Design only — `1b` builds the loop,
`1c` rehearses the restore. Measured at `d0aff782eed27ad1c40f594c135942bd1c1c8b1f`, deployed as
worker `etag 8cb2680e…` with `prov:source-sha=d0aff782…`.

---

## 1. The inventory, measured — and the finding it produced

⭐⭐ **THE FIRST FINDING IS THAT REALMS CAN BE COUNTED AND CANNOT BE NAMED.**

`[measured 2026-09-04 14:2xZ · GET /accounts/d5c4856e…/workers/durable_objects/namespaces/<id>/objects]`

| namespace | objects | with stored data |
|---|---|---|
| `commonplace-log_CommonplaceLog` | 0 | 0 |
| `commonplace-log_RealmContainer` | 4 | 3 |
| `commonplace-log_RealmNode` | **38** | **38** |

⛔ **The listing returns exactly two fields per object — `id` and `hasStoredData`. There is no name.**
Realms are addressed by `namespace.idFromName(realmId)` (`worker/src/index.ts:91`) and
`getByName(realmId)` (`:77`), and `idFromName` is a **one-way** derivation: the hex id cannot be
turned back into the realm id. ⇒ **Nothing in the platform or in `worker/src` can list the realms
that exist.** (`worker/src` contains no registry, index or catalog: the single `list` hit is
`indexOf`; control — `frontier` appears 24 times, so the search was not blind.)

⚠️ **AND THE MEASUREMENT ITSELF NEARLY LIED, in a way worth recording:** `?limit=3` and `?limit=10`
return `success:false, 10077 limit is too low` — and a caller that reads `result` from that response
gets `None` and prints *"0 objects"*. ⛔ **A refused request and an empty namespace are the same
observable unless you read `success`.** The 38 above comes from a call that returned `success:true`.

⇒ ⭐⭐ **CONSEQUENCE FOR THE DESIGN, and it is the whole shape of it: A BACKUP CAN ONLY WALK REALMS
IT WAS TOLD ABOUT. There is no discovery. So the registry is not a convenience — it is the only
thing standing between "backed up everything" and "backed up everything I happened to know".**

✅ **AND THE COUNT IS THE REGISTRY'S CONTROL.** The DO objects listing cannot name realms, but it can
COUNT them. ⇒ **Every run asserts `registry entries == RealmNode objects with stored data`, and
refuses loudly when the registry is smaller.** ⛔ **Without that, a realm created by a path that
forgets to register is invisible to the backup and to every check of the backup — the failure is
silent at both ends.** ⭐ **Two independent enumerations, in different systems, that must agree.**

---

## 2. Where the backup runs — **a SECOND Worker, and the argument is measured, not aesthetic**

**Option A — a Cron Trigger on the existing `commonplace-log` Worker.** Cheapest to write: the DO
bindings already exist.
⛔⛔ **REJECTED, on a blast radius measured today:** `worker/wrangler.jsonc` carries a `containers`
block whose build context is `../commonplace_log`, and its Dockerfile is `COPY config` + `COPY lib`.
⇒ **`wrangler deploy` on this Worker BUILDS AND ROLLS OUT THE BEAM IMAGE.** On 2026-09-04 that
deploy moved `commonplace-log-realm` from **v5 to v6 across 7 live instances**.
⭐ **So every iteration of the backup — every fix to a loop bug, every layout tweak — would roll the
live storage engine.** ⇒ **The backup's change cadence would become the live engine's rollout
cadence, which is the opposite of what a durability feature should cost.**
⚠️ Second, smaller: a `scheduled()` handler that throws, loops, or exhausts CPU shares a deployment
with the live serving path.

**Option B — a second Worker `commonplace-log-backup` (RECOMMENDED).** Its own script, its own
deploy, its own R2 binding, its own cron. It reaches realms through a Durable Object binding that
names the other script's namespace (`durable_objects.bindings[].script_name = "commonplace-log"`),
so it talks to the SAME realms without owning them.
✅ **Blast radius: a backup bug cannot roll the container, cannot redeploy the live script, and
cannot take the serving path down.** ✅ **Its deploys are `worker/`-only and carry no image.**
⛔ **Cost, stated rather than hidden:** a second script to keep in sync with the realm HTTP surface —
**the same "stub of a surface you do not own" drift that `bin/sidecar-stub` carries.** ⇒ **Mitigation
is the one already proven: the backup Worker records the `commonplace-log` sha its expectations were
written against, and a check compares that pin to the deployed `prov:source-sha`.**

---

## 3. Object layout in R2 — append-only, idempotent by construction

```
<realm_id>/<writer_id>/<seq padded to 12>.json    one entry per object, written ONCE, never updated
<realm_id>/frontier.json                          per-writer tips, written LAST in a run
_runs/<run_id>.json                               the run log (BACKUP-1b)
```
⭐ **Append-only is not a policy here, it is a property of the data:** entries are content-addressed
(`entry_id` UUIDv7) and chained per writer (`prev_entry_id`), so an entry at `(realm, writer, seq)`
is immutable. **Re-running the loop re-derives the same key with the same bytes.** ⇒ **A second run
appends zero objects — which is `1b`'s idempotence arm, and it is checkable by counting.**
⭐ **`frontier.json` LAST is the commit point:** a run that dies mid-walk leaves entries without an
advanced frontier, and the next run simply resumes. ⛔ **Never write the frontier first — that turns
a partial backup into one that claims completeness.**

---

## 4. Custody of read capabilities

**Who mints:** `STORE-3b` makes `/realm/read-capability` a **write-authenticated** route, so only the
holder of a realm's write secret can mint its read capability. That is the realm's creator —
`commonplace-next`'s create flow. ⇒ ⭐ **The backup never holds a write secret and therefore cannot
write, mint, or revoke anything. Its authority is exactly four routes: `/frontier`, `/read-set`,
`/read-writer`, `/tail-local`** (`worker/src/realm/realm_auth.ts:94`).

**Where it lives:** a KV namespace keyed by `realm_id`, written ONCE by the minter at realm creation,
bound **read-only** to the backup Worker. ⛔ **Never in R2** (R2 holds the backup, and a backup that
contains the credentials for the thing it backs up is a single object that is both the data and the
key to it). ⛔ **Never in a message, a row, or a repo** — `STORE-3b`'s rule, unchanged.
✅ **This one object serves BOTH custody and enumeration** — it is the registry of §1, and the DO
object count is its control.
⚠️ **Open, and named rather than assumed:** the KV write happens in `commonplace-next`'s create flow,
which is not this round's repo. **`1b` cannot walk a realm created before that write exists**, and
`STORE-3b`'s R3/R4 already establish that pre-existing realms can be minted for retroactively.

**Revocation:** minting again revokes the prior capability. ⇒ **A revoked capability must stop that
realm's backup with a NAMED error in the run log, never silently** — a realm that stops being backed
up looks exactly like a realm with no new entries.

---

## 5. Restore — an operator act, not the backup's

Replay is per writer, in `seq` order, through the **write** routes into a fresh realm. ⇒ **It needs a
write secret, which the backup does not have and must not have.**
⛔ **So restore is an OPERATOR act, deliberately.** The backup Worker has no code path that can write
to a realm; that is the property that makes a compromised backup unable to corrupt the live store.
⭐ **`1c` is the arc's exit condition and its assertion is written down now, before `1b` is built:**
a realm with N entries across W writers is backed up, a FRESH realm is restored from R2, and
`/frontier` of the restored realm equals the original's per-writer tips **with every `entry_id`
identical**. ⛔ **`entry_id`s, not counts** — equal counts is the comparison a broken restore passes.
⭐ ***A backup nobody has restored is not a backup.***

---

## 6. What this round did NOT do

⛔ No change to `READ_ROUTES`, no new auth surface, no write route touched. No cron trigger, no
binding, no deploy. **One R2 bucket `commonplace-log-backup` created** (recorded in `boss-clod`
`cf-records/commonplace-log-backup.md` with its removal path RUN, not merely written), **and no data
in it** — the rehearsal object was deleted and the listing shown both ways.

---

## 7. CORRECTION — what §4 said, what is true, and how the difference was found

⛔ **§4 above was written as: *"minted at realm creation by the write-secret holder… the only place
the write secret is in hand."* THAT SENTENCE IS WRONG, and it is left standing above rather than
edited, because a design doc that silently self-heals is a record nobody can audit.**

**What is true** `[measured at c4b3a4d, worker/src/realm/realm_auth.ts]`:
```
create(realmId)        generates the secret, stores only its HASH, and RETURNS the plaintext once
                       (:188) ⇒ the write secret LEAVES the DO, to the gateway/creator
mintReadCapability()   TAKES NO ARGUMENT. It never reads, verifies or receives the write secret.
                       Its guards are storedHash !== null and storedReadHash === null.
```
⇒ ⭐⭐ **THE AUTHORITY TO MINT IS *BEING INSIDE THE DO*, NOT HOLDING THE SECRET.** The write-secret
framing is true of the HTTP route — `/realm/read-capability` sits behind `authorize() === "write"` —
and the sentence generalised a route's guard into a property of the operation.

✅ **The correction makes the design STRICTLY BETTER, which is why it is not merely an erratum:** the
registry write mints in the create branch with the write secret **never an input**, so no code path
in `BACKUP-1b-i` touches, copies or stores it. **What the write-secret framing was trying to buy is
bought by locality instead.**

**How it was found:** the sentence was written from the ROUTE TABLE. It was checked by reading the
IMPLEMENTATION it was a claim about, because the round that depends on it was about to be built on
it. ⭐ ***A claim written from one artifact is not evidence about a different one.***

## 8. `1b-i` as built — and the DEPLOY ORDER it forces

`registerRealm()` reports a `RegistryOutcome` in the create response: `registered` ·
`already_minted` · `registry_write_failed` — and **`no_registry_bound` is a 503 REFUSAL, not a 201**
(plan row 855: a 201 over an unregistered realm is the system ANSWERING instead of DECLINING).
⛔ **The binding is checked BEFORE `create` runs.** Refusing after would leave an ORPHAN: a realm
that exists, is unregistered, and whose write secret the caller never received.

⛔⛔ **THEREFORE A DEPLOY ORDER, AND IT IS NOT OPTIONAL: THE KV NAMESPACE AND THE `REALM_REGISTRY`
BINDING MUST EXIST BEFORE THIS CODE DEPLOYS. Deployed without them, REALM CREATION STOPS.**
⭐ **Measured, not reasoned: binding it in `wrangler.test.jsonc` is what took 20 red arms in
`http.workers.test.ts` back to green. The test corpus reproduced the outage in miniature.**

## 9. Correction: enumerate logs, preserve log identity, and use writer cursors

BACKUP-1b-ii preflight, 2026-09-05 at `b75ac47`; ruled by commonplace-plan,
ledger row 1000 / plan `38458dd`, clod-squad message 29837. Sections 3 and 4
remain above as historical statements, including the incorrect ones.

The first backup prompt described reading a frontier for each realm, then using
`tail-local` per writer. The implementation exposes only **per-log** frontiers:
every existing read route needs `log_id`, but the registry contains only realm IDs.
The missing operation is log enumeration. This round adds a paginated
`POST /list-logs` (`after_log_id`, `limit`; response `log_ids`, `next_after_log_id`)
and admits it through the existing READ scope. That scope is realm-wide; there
was no per-log authorization restriction to widen. Reads of an empty realm
return an empty inventory without creating the log schema.

The storage schema makes `(log_id, writer_id, writer_seq)` unique. Section 3's
old key drops `log_id`, so two legitimate entries can map to one R2 object.
The corrected layout is:

```text
<realm_id>/<log_id>/<writer_id>/<seq padded to at least 12>.json
<realm_id>/<log_id>/frontier.json
<realm_id>/manifest.json
_runs/<run_id>.json
```

Each identifier path segment is percent-encoded. Entry objects contain the exact
canonical bytes returned by the source; frontiers record per-writer sequence and
entry ID; the realm manifest records the log IDs. Entries are immutable by
conditional creation and byte comparison, not because UUIDv7 is content-addressed
(Section 3's description of UUIDv7 as content-addressed was also incorrect).

Use `/read-writer` with `after_seq` and the captured frontier's `through_seq`.
`tail-local` takes `after_arrival`: its cursor is realm-wide, replica-local arrival
metadata and is not a writer sequence. A log's frontier is written after its
entries, and the realm's manifest after all enumerated log frontiers. Failed
checkpoint writes leave the previous checkpoint intact; retries compare existing
entry bytes rather than overwriting them. Concurrent checkpoint writes use ETags.

Section 4 also says minting again revokes the prior capability. The implementation
refuses a second mint with `409 read_capability_exists`. Rotation is explicit
revocation followed by minting. The revocation test now revokes, runs the backup,
and checks for `capability_rejected` in the persisted run log; it separately pins
the second-mint refusal. Generated test capabilities stay in temporary memory/KV.

These discrepancies were found by reading the HTTP handlers and uniqueness
constraints before implementing the prose. The separate-Worker decision remains
unchanged. Its registry interface exposes only `get`/`list`; this is a code
restriction, not a claim that Workers KV bindings have a platform read-only mode.
The run explicitly reports `registered_realms_only`: pre-registry realms are not
backfilled here, and production registry/DO-count reconciliation remains 1b-iii.
Restore verification remains 1c; this round does not certify a usable restore.

## 10. Decision: derived backup keys are sensitive metadata (BACKUP-KEYS-1)

At log base `7c9d9ca`, choose **B: retain derived keys, classify listings as
sensitive, and enforce review of production output paths** (planner ruling
29918). This is an explicit choice rather than the previous default. The backup
Worker remains undeployed; this decision does not authorize deployment or change
any bucket access policy.

A fixture-only reproduction uses commonplace-next Identity and Membership at
`94abc915604cf93ee6c604d33bc2e14ae2d61441`. Ten literal Elixir-produced vectors
validate the hash, UUID stamping and discriminated form before the membership
probe. An independently supplied Python membership chain provides another
control. The backup itself produces a local listing; a guessed fixture member
and generation match it, while another member and another generation do not.
The working oracle is the finding. This confirms a guessed membership, not an
ability to enumerate unknown members or prove current membership: old cells can
remain after membership changes. The organization, candidate member and generation
must be known or guessed. The IDs also disclose document identities, because the
document caller uses document_id as log_id.

Both costs inform the choice:

- **A, keyed/opaque log segments:** protects an index-only disclosure when the
  mapping secret is unavailable. It adds persistent mapping/key custody and a
  recovery dependency. Contrary to the brief's original claim, losing the mapping
  need not cause duplication: a fail-closed implementation stops with a named
  outage until the mapping is recovered. Generating a replacement silently is the
  failure that would duplicate objects. A simple random realm prefix with raw log
  IDs would not conceal the log IDs at all. Opaque entry keys also do not conceal
  an unmodified manifest's log_ids from a reader of that manifest.
- **B, retained derivation:** keeps key identity reproducible without an extra
  mapping and preserves the tested zero-append repeat behavior. It leaves a real
  confidentiality cost: a copied index alone can confirm guesses and disclose a
  document inventory. Calling that index harmless would be wrong, even if the
  same authorized bucket reader can also retrieve more sensitive document bytes.

B is selected for this implementation because it preserves the existing recovery
model and adds no secret that must survive alongside backups. This is not a claim
that confidentiality is less important than durability, or that A cannot be made
reliable. A remains appropriate if a future requirement explicitly permits index
access while forbidding identity disclosure; that would require a designed,
recoverable mapping and a review of manifest disclosure too.
The random-prefix and unchanged-manifest gaps are defects in how the brief
specified A, not reasons to prefer B over a correctly specified opaque scheme.

**Custody:** bucket contents AND listings must be handled as sensitive as the
membership roster and document inventory. Never paste a live index, manifest or
run payload into a channel, ticket, or run report. Synthetic fixtures are explicitly
identified and may appear in tests and evidence. Boss owns the corresponding
`cf-records/commonplace-log-backup.md` entry and any access-policy change; this
round requests that record and makes no Cloudflare call. No effective production
access policy was measured here. Deployment remains separately held.

**Mechanism and limits:** `check-backup-boundary.sh` now invokes a SHA256 integrity
gate over the entire reviewed production backup source set. The reviewed output
paths are realm read queries and R2 writes; the scheduled entry returns no payload
and can report a fixed failure code with an opaque run ID. No manifest, inventory
or run payload is emitted to console, an HTTP response or another binding. Any
code edit or new module fails until its output paths are reviewed and the recorded
hashes are deliberately updated. The test injects both direct and aliased debug
outputs and an extra module; the gate rejects them, and passes after restoration.
This is a review gate over known code, not semantic analysis of arbitrary code.
Hash updates require review, not mechanical regeneration.

A static check on the worker's source cannot prevent an operator copying a
manifest out by hand. Tests, fixture artifacts, operator exports and provider
telemetry are outside this gate and are printed as exclusions by the tool.
Platform logging and human disclosure therefore remain custody obligations, not
properties this gate proves. Earlier sections and the brief remain historical;
this section corrects the assumption that identifier-free credentials imply
identifier-free backup metadata.

## 11. Reconciliation: absence, unknown reads, and an administrative boundary

At base `330c013`, registry cleanup lives in `worker/reconciliation`, separate
from the backup's pinned read-only modules. No production entry or binding is
added. Default dry run writes nothing; a returned report names every examined
row as present, absent or unknown. Only a DO response of 404 with the explicit
not_found error body establishes absence. Failed requests and failed safety
rechecks remain unknown and never delete.

Apply mode is opt-in and requires explicit acknowledgment of an externally
quiescent realm-lifecycle window. A pre-delete byte recheck is mandatory but is
not atomic compare-and-delete. Recreation can still race it; eventual KV reads
can also be stale. This limitation is not disguised as concurrency safety.
Planner ruling 29945 ranks the closing mechanism as `REGISTRY-SELF-DELETE-1`:
perform administrative cleanup inside the DO while holding its lifecycle gate,
with the necessary authority change reviewed separately. This round changes no
READ_ROUTES, capability minting, creation or removal path.

The report independently records registry key count and an instrument-labelled
stored-DO count; failed observation is null. Their signed difference exposes a
count disagreement. Equal counts can hide one orphan and one unregistered realm;
they do not establish identity agreement. Local arms measure KV and user storage
on separately enumerated DO IDs. No production count is inferred from fixtures.

The inverse repair remains outside this repository: commonplace-next knows the
realm IDs it created and is the starting point for a backfill inventory. A DO
objects listing supplies opaque IDs and hasStoredData, not the names needed by
idFromName. A known name alone also cannot recover an existing read secret; that
custody problem needs an operator with suitable authority, not an automatic mint.
Reconciliation reports contain sensitive realm identifiers and must stay under
the metadata custody decision in §10. The library returns its report in memory;
production invocation and protected report persistence remain unwired.
