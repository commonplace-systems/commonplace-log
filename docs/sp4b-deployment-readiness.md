# SP4b deployment readiness — what is needed, and what has not been verified

**Status:** SP4a complete as of 2026-08-23. **jes approved SP4b in principle on 2026-08-23**
("I'll try to set up the cloudflare soon"); it is gated on account credentials and Containers
access, not on the decision.

**§8.3 Container lifecycle supervision — ruled out of scope 2026-08-23, then REOPENED the same day**
when jes described the intended library stack (`log → reducers → commonplace-doc → directory →
cell`, a cell running in a realm, a realm being roughly a single server) and asked whether *realm*
reaches down to the log layer. See §4 for what exists, and §4a for the layering answer. ⚠️ The
machinery is still **absent** either way; only its scope is in question.

This document exists to make that decision on real information rather than on a green tick. Its
most important section is the last one.

---

## 1. What SP4a built, and how far the evidence reaches

| Task | Commit | What it establishes |
|---|---|---|
| 1 | `4ea6e4e` | Realm store: proposal §7.2 schema on **real DO SQLite**, revision + epoch CAS, three read paths, and a transitive import-graph gate enforcing §9's semantic boundary |
| 2 | `7c43530` | `RealmContainer` serving §6 over HTTP; round-trip count gated at exactly `[/read-set, /commit]` |
| 2.5 | `9ce7af0` | `/take-lease`; the store owns `received_at_ms` and the wire rejects it |
| 3 | `5d680ab` | `Persistence.CloudflareSidecar` over an injectable transport (`:httpc`, no new dependency); strict entry decoding |
| 4 | `73caa5f` | Lost acknowledgements resolve to exactly-once, or to an explicit unknown |
| 5 | `a8752e4` | **The acceptance criterion:** identical Engine behaviour over LocalSQLite, in-memory, and the sidecar — with the suite demonstrated able to fail against three deliberately broken adapters |
| 6 | `a1b1201` | Elixir against a real `wrangler dev` over a real socket, gated by a positive control |

Suites: **elixir 239 tests + 5 properties; worker 249.** All green.

**The strongest single result** is Task 6 finding *no* disagreement between the adapter and the
real wire — statuses, JSON shapes, and a non-UTF-8 payload surviving Elixir → base64 → JSON/HTTP →
workerd → storage → re-encode → Elixir. That is the best available evidence that the loopback
double used by Tasks 4 and 5 was faithful, which is what makes their results transferable.

---

## 2. What SP4b needs from jes

1. **A Cloudflare account** with Workers and Durable Objects.
2. **Containers access.** The primary deployment runs BEAM inside a named Container with its
   managing Durable Object as the durable SQLite sidecar (revision §§1, 8). ⚠️ **There is no local
   equivalent of Containers**, which is the hard line SP4a was split on: everything above runs
   under `wrangler dev` locally, and nothing below can be honestly asserted from this box.
3. **Realm naming and placement policy** — how a `realm_id` is chosen and how a Container maps to
   its managing DO.
4. **Gateway authentication.** `401`/`403` are gateway-side and were deliberately left out of the
   sidecar (SP2 recorded this). Something must resolve an authenticated realm before the request
   reaches the Container.
5. **The outbound handler** intercepting `http://storage.internal`, deriving the realm from
   `containerId`, and invoking the managing DO's stub. This is Worker-side TypeScript and does not
   exist yet.

---

## 3. ⭐ The security property only SP4b can verify

Proposal §8.2 makes the outbound handler responsible for deriving the realm from `containerId`, so
that **the BEAM request cannot select another client's realm.**

⛔ **Nothing in SP4a tests this**, and nothing could. It is a property of deployed configuration:
the adapter is deliberately Cloudflare-ignorant, talks to a configured base URL, and has no concept
of a realm at all — which is exactly what keeps the two adapters interchangeable, and exactly why
this guarantee lives somewhere SP4a cannot reach.

⇒ **Treat this as unverified until it is tested against a real deployment with at least two
realms.** A single-realm deployment cannot distinguish "the handler scopes correctly" from "there
was only ever one realm to return."

### ⭐ RESOLVED 2026-08-23 — this property is v1, load-bearing, and has no local test

jes, asked directly:

> "a log lives in a single realm. in fact, a cell lives in a single realm. but I may have
> **multiple realms per tenant**"

⇒ **"Single-realm" is a containment statement about each object — a log lives in one realm, a cell
lives in one realm. It is not a claim that few realms exist.** Multiple realms per *tenant* means
strictly more realms than one per customer.

⛔ **So cross-realm isolation is a v1 correctness property, not a v2 concern**, and it is the
headline item of this document: **the BEAM request must not be able to select another client's
realm.** Nothing local can verify it, by the sentence above — with one realm there is nothing to
isolate from.

⇒ **Verifying it requires a deployment with at least two realms, and that verification is not
optional for v1.** It is the single strongest argument for the §5 ordering below, which reaches
two-realm isolation before BEAM enters the picture.

⭐ **But it is deferred by exactly one fact, not by the whole deployment.** The property splits:

| Half | Needs an account? |
|---|---|
| The handler ignores any client-supplied realm and derives solely from `containerId` — *"a request naming realm B with a `containerId` for realm A resolves to A"* | **No.** A pure unit test, once the `containerId` shape is known |
| The platform supplies a `containerId` that cannot be forged, and interception cannot be bypassed | **Yes** |

⇒ The outbound handler is blocked on **the shape of `containerId`** — a single observation from a
real environment — rather than on the full deployment. ⛔ Do not write it before that observation:
a function whose argument type is a guess is rework with a head start, not preparation.

---

## 4. ⭐ Every claim SP4a could NOT verify

This is the section to read before deciding.

**Storage exhaustion.** `storage_full` has **never been exercised**, in SP2, Task 1, or Task 2.
workerd rejects `PRAGMA max_page_count` with `SQLITE_AUTH`, so exhaustion cannot be induced
locally. Only the 507 mapping and the exact spelling are pinned. ⇒ **A mapping that has never run
is a spelling, not a behaviour.** The first real disk-full event will be its first execution.

**Container ↔ DO colocation and latency.** §8.2 states they are not guaranteed to be colocated.
Everything measured locally *was* colocated. The round-trip discipline (one read set, one commit)
is enforced by test, but its actual latency cost is unmeasured.

**Named addressing end to end.** SP2 recorded that `ctx.id.name` is always `undefined` under
vitest-pool-workers, deferring real `idFromName` verification to wrangler-dev. Task 6 drove a
test-only entry point forwarding to one named `RealmContainer`; it did **not** verify production
name-based addressing across many realms.

**Container lifecycle (§8.3) — ⛔ NOT UNTESTED. NOT BUILT, AND OUT OF SCOPE.** The revision
describes a fresh BEAM booting, a realm supervisor starting, and log processes reconstructing on
demand. ⚠️ **None of that machinery exists.** Measured 2026-08-23: `commonplace_log/lib` has one
`DynamicSupervisor`, keyed per `log_id`; there is no realm-level supervisor or registry, and the
word *realm* appears in that tree only in documentation comments. So there is nothing to
reconstruct log processes on demand, and nothing to reconstruct them *from* at the realm level.

**jes ruled this out of scope on 2026-08-23 and reopened it the same day** — see §4a. The
machinery's absence is unchanged; what is open is which library should own it.

⭐ Recorded this way on purpose. "Untested" and "absent" read identically to someone planning a
deployment, and only one of them means the supervision story is unhandled. A reader would otherwise
have no way to tell a description of intended machinery from a description of existing machinery.

**Real network failure.** Task 4's lost acknowledgement is injected through the transport seam: the
double performs a real commit and then drops the reply. This is a faithful *shape*, but no real
socket, timeout, partition, or retry storm produced it. Production HTTP scheduling is unexercised.

**Concurrent Realm Containers — ⚠️ OPEN ON BOTH AXES.** jes ruled logs and documents
**single-realm for v1**, which removes one log being live in two *different* realms — but he also
confirmed **multiple realms per tenant**, so distinct realms running concurrently is ordinary v1
operation, not an exotic. And the second axis below is untouched by the ruling entirely.

⛔ **It does not remove the case the epoch actually fences.** Revision §51: "a Container is one
restartable BEAM-node **incarnation**". SP-DP records that a Realm is replaced on rollout, and
"slept on idle and woken elsewhere, so **handoff is an ordinary lifecycle event**." ⇒ A single realm
has **many successive incarnations**, and two activations of the *same* realm can transiently
coexist during a rollout — the old one draining while the new one starts. **That is precisely what
an obsolete epoch failing at commit prevents**, and it is unaffected by the single-realm ruling.

⇒ **The epoch stays load-bearing in v1.** What is untested remains the *deployment* condition —
two live incarnations on separate disposable disks — not the mechanism, which is exercised across
three adapters (monotonic advance, obsolete-epoch rejection distinct from stale-revision, no rows
written on rejection).

**Sharding (§7.3).** One realm database is the default. The placement directory mapping a log UUID
to a shard DO is designed but not built.

---

## 4a. ⭐ Does *realm* reach down to the log layer?

jes asked this on 2026-08-23, describing the intended stack: `log → reducers → commonplace-doc →
directory → cell`; a cell runs in a realm; a realm is roughly a single server.

**It already does — physically — and that part is built.** Revision §7.2's realm database holding
many UUID-addressed logs is Task 1 (`4ea6e4e`). *Realm* is already a storage grouping at this
layer, and the multi-log isolation tests exist precisely because of it.

**It must not, logically, and the profile says so twice:**

> A Realm is not the root authority for a Document merely because its storage sidecar contains the
> Document's bytes. (§ profile:117)

> Its database may hold logs belonging to several Cells hosted by a Realm. This physical
> containment MUST NOT be interpreted as logical ownership of those Cells or logs. (§ profile:310)

⇒ **Realm reaches log as containment, never as authority.** That distinction is already load-bearing
in three moduledocs in `commonplace_log/lib`, which state the chain Realm → Cell → Document → log
handle → persistence. jes's stack and the existing prose agree.

### What that means for §8.3, which is the live question

§8.3 bundles two different things, and they belong to different libraries:

| §8.3 element | Owner | Why |
|---|---|---|
| Container lifecycle, stable realm identity, routing, wakeup | **the sidecar / realm layer** | Revision §2 assigns these to the sidecar explicitly; the durable inbox is scoped out of v0.1 by §8.3 itself |
| **Log processes reconstructing on demand** | **arguably this library** | Needs only a `log_id` and a store. No Cell, Document, or Directory concept enters it |

⭐ **The discriminator is what the supervisor must know.** "A request arrives for log X; start a
server for X if one is not running" requires nothing above the log layer. Anything that must know
*which Documents belong to which Cell* is above it and belongs in `commonplace-doc` or the cell
library.

### ⭐ Current state — corrected 2026-08-23. The log-layer half is ALREADY BUILT.

⚠️ **An earlier revision of this note said "no registry, so nothing can find or reconstruct a log
server by id." That was false.** Measured directly:

```
application.ex:9   {Registry, keys: :unique, name: Commonplace.LogStore.SQLite.Registry}
application.ex:10  {DynamicSupervisor, strategy: :one_for_one, ...}
sqlite.ex:86       server_for/2 -> Registry.lookup(log_id)
                     [{server,_}] -> Process.alive?(server) ? use : start_server
                     []           -> start_server
sqlite.ex:108      DynamicSupervisor.start_child/2, tolerating {:already_started, server}
server.ex:46       name: {:via, Registry, {@registry, log_id}}
```

⇒ **`server_for/2` IS "a request arrives for log X; start a server for X if none is running"** —
the exact discriminator argued above — **including the dead-server case and the start race**, which
are the harder halves. It knows only `log_id`, `data_dir` and mode; nothing above the log layer
enters it.

**So §8.3's log-layer half is not a gap. It is done**, and it satisfies containment-not-authority
in code rather than only in prose.

**What remains genuinely absent is realm-level only:** there is no realm supervisor and no realm
concept in code at all — `realm` appears in `commonplace_log/lib` in three moduledocs and nowhere
else. Per §4a that belongs above this library.

**Revised recommendation:** ⛔ **nothing to build here.** The primitive a cell-library realm
supervisor would drive already exists. ⚠️ Any §8.3 work belongs in the cell layer, not in
`commonplace-log`.

⭐ **Why the false claim is recorded rather than quietly deleted:** it was produced by a selector
that could not see its subject. A wide grep for `Registry|DynamicSupervisor|Realm` *did* list
`application.ex`; a second, narrower grep for `Supervisor|children` could not match line 9, which
contains neither word — and the narrow result was believed over the wide one that had already
flagged the file. A pattern anchored to how a name is usually written (`Registry.`, with the dot)
is not anchored to the name.

---

## 4b. ⭐ SP4b progress — 2026-08-24, against the real account

jes supplied an account API token on 2026-08-24 (stored outside every repository; read from the
environment only). Measured the same day:

**⛔ The account has no Containers access.** The API answers verbatim: *"Deploying containers
requires the Workers Paid plan."* SQLite-backed Durable Objects are available on the current plan.
⇒ §5 steps 1–2 could proceed and did; **steps 3–4, and the `containerId`-shape observation that
gates the §3 outbound handler, are blocked on a plan upgrade** — an owner's decision, not work.

**Steps 1–2 are deployed and verified.** `worker/src/index.ts` is now a production ingress:
`/realms/{realm_id}` + sidecar path → `REALM_CONTAINER.getByName(realm_id)`, behind
`Authorization: Bearer` checked against the `GATEWAY_TOKEN` Worker secret in constant time. A
gateway with no secret configured answers 503 to everything but `GET /` — it fails closed. The
realm is derived only from the path; this is the pre-Container gateway, not the §3 handler.

Deployed to `https://commonplace-log.commonplace-systems.workers.dev`. Run by hand over the public
internet, in this order:

| Probe | Result |
|---|---|
| `GET /` | 200 |
| no token / wrong token → `/realms/A/frontier` | 401 `unauthorized`, token never echoed |
| unknown top-level path | 404 |
| realm A: `create-log`, `commit` one entry, `frontier` | 201, revision 1, `alice seq 1` |
| **realm B: `frontier` for the same `log_id`** | **404 `not_found`** |
| positive control: realm B creates its own log, reads it back | 201, empty frontier |
| realm A asks for B's log | 404 |
| realm A `frontier` again, later request | still `alice seq 1` — durable across requests |

⇒ **Named addressing end to end and real DO SQLite are now verified** (closing two §4 items), and
**cross-realm isolation holds in its path-derived form**, with the presence control read before the
absence was believed. What this does *not* show is the §3 property proper — that a BEAM inside a
Container cannot *choose* its realm — because no Container exists to be scoped.

**⭐ The `containerId` shape is observed (2026-08-24, later the same day, after jes moved the
account to Workers Paid).** A throwaway probe worker — a `Container` subclass whose outbound handler
for `storage.internal` echoed its `ctx` — showed, on two realms:

```text
handler ctx.containerId  = e1180131…6911   (realm-x)      3be25ac7…bd6c   (realm-y)
managing DO ctx.id       = e1180131…6911                  3be25ac7…bd6c
idFromString(containerId) round-trips to the same id on both
```

⇒ **`containerId` IS the managing Durable Object's id.** The handler can resolve
`env.BINDING.get(env.BINDING.idFromString(ctx.containerId))` and can cross-check any DO-supplied
parameter with `idFromName(realm).toString() === ctx.containerId`. The platform supplies the id;
the BEAM request carries nothing that participates. The §3 "do not write it before the observation"
gate is lifted.

Two traps met on the way, recorded because each looked like something else:
- The entrypoint must `export { ContainerProxy } from "@cloudflare/containers"` or the container
  fails to start with "ctx.exports.ContainerProxy is undefined" — a *start* failure, not a routing one.
- `static outboundByHost = {...}` as a TS class field is DEFINED as an own property (ES2022
  semantics) and never reaches the SDK's static *setter*, so no handler registers and the request
  falls through to the real internet — where `storage.internal` answers **530 (origin DNS error)**.
  Assign `Klass.outboundByHost = {...}` after the class instead. A 530 here means "unhandled", not
  "blocked" (that is 520).

Still unverified from §4: storage exhaustion, Container↔DO latency, real network failure under
production scheduling, two live incarnations of one realm. Nothing about those changed.

---

## 5. Recommended shape for SP4b, if it proceeds

Ordered so the unverifiable items become verifiable as early as possible:

1. Deploy the Worker and `RealmContainer` **without** Containers first — this makes named
   addressing and real DO SQLite testable against an account with no BEAM involved.
2. Add the gateway and outbound handler; **test realm isolation with two realms** before anything
   else, per §3 above.
3. Introduce the Container running BEAM.
4. Then, and only then, exercise lifecycle: kill a Container mid-commit, force a rollout, and
   confirm the epoch fences the displaced activation.

⚠️ Step 4 is where the fencing epoch is finally tested against the condition it was designed for.
Until then it is a mechanism that works in principle and has never met its motivating case.

---

## 6. What must not change

The §2/§3 exclusions are decisions, not gaps: no Merkle trees, CRDTs, total order, consensus,
deletion or compaction, signatures. `docs/commonplace-monotonic-log-spec.md` stays byte-identical.
`conformance/` is a cross-repo surface — byte-rule, numbering or `expected.hex` changes must be
announced to `commonplace-log-reducer`; adding vectors is safe. The SP2 workalike under
`worker/src/do/` is frozen. `Engine`, `MergePlan` and `Sync` semantics stay as they are.
