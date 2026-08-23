# SP4b deployment readiness — what is needed, and what has not been verified

**Status:** SP4a complete as of 2026-08-23. SP4b (real Cloudflare deployment) is **not started and
should not be started without a decision from jes.**

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

**Container lifecycle (§8.3).** Cold start, rollout, crash, migration, and pending durable inbox
redelivery are entirely untested — a fresh BEAM booting, the realm supervisor starting, and log
processes reconstructing on demand.

**Real network failure.** Task 4's lost acknowledgement is injected through the transport seam: the
double performs a real commit and then drops the reply. This is a faithful *shape*, but no real
socket, timeout, partition, or retry storm produced it. Production HTTP scheduling is unexercised.

**Concurrent Realm Containers.** The fencing epoch exists precisely because two Containers may hold
the same log with separate disposable disks. ⇒ **That scenario has never actually occurred.** Epoch
CAS is tested against a single store; the deployment condition that motivated it is unreproduced.

**Sharding (§7.3).** One realm database is the default. The placement directory mapping a log UUID
to a shard DO is designed but not built.

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
