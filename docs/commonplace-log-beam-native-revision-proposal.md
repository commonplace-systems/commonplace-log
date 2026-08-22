# Proposal: Recenter `commonplace-log` on a BEAM-Native Engine

**Date:** 2026-08-21

**Status:** Proposed revision

**Repository reviewed:** `commonplace-systems/commonplace-log` at `75a4a208c7672664141ff4abc8f93205d2365313`

## Executive decision

`commonplace-log` should define Commonplace's log semantics in Elixir and treat the Elixir implementation as normative. Cloudflare Durable Objects remain first-class deployment infrastructure and the existing pure Durable Object implementation remains valuable, but it is classified as a conforming workalike rather than the reference implementation.

For the primary Cloudflare deployment, a named Cloudflare Container is treated as a restartable BEAM server with a durable SQLite sidecar supplied by its managing Durable Object:

```text
<tenant>.commonplace.st
          |
     Gateway Worker
          |
   Realm Container DO
      /          \
durable SQLite   BEAM Container
sidecar          Commonplace server
```

The BEAM server owns entry construction, canonicalization, merge classification, synchronization, cells, authorization, and application interpretation. The sidecar owns stable realm identity, durable bytes, atomic compare-and-commit, routing, and Container lifecycle.

The default physical unit is one Container-managing Durable Object per client realm, not one Durable Object per log. A realm database may contain many UUID-addressed logs. Per-log Durable Objects remain an optional sharding strategy and the basis of a lightweight non-BEAM workalike.

This revision preserves the protocol, conformance corpus, completed Durable Object implementation, and almost all planned Elixir work. It changes which implementation is normative and introduces a new persistence boundary for the BEAM-on-Cloudflare deployment.

## 1. Why revise now

The current specification and implementation plan make a SQLite-backed Durable Object the canonical online log authority. In that architecture:

- one physical Durable Object database stores one logical log;
- TypeScript validates entries and classifies merges;
- the Durable Object exposes the complete log protocol;
- `Commonplace.LogStore.Cloudflare` makes Elixir a client of that service; and
- the Container is application compute in front of a set of log authorities.

That is internally coherent, and the completed SP2 implementation is unusually well tested. It is also the wrong center of gravity for an Elixir-first Commonplace. The normative implementation of Commonplace's foundational data structure would be TypeScript, while the BEAM implementation would be a port required to remain in lockstep.

Cloudflare's runtime suggests a different composition. Every Container is already managed by a Durable Object with stable identity, SQLite storage, and lifecycle hooks. The Container can reach Worker bindings and its own managing object through an outbound handler. This permits Durable Objects to provide a durable shell around a BEAM server without becoming the semantic center of Commonplace.

This boundary also respects the difference in granularity:

- a BEAM process is a cheap, volatile, crashable execution unit;
- a UUID log is a logical durable unit managed by BEAM processes;
- a Durable Object is a heavier durable jurisdiction or storage shard; and
- a Container is one restartable BEAM-node incarnation within that jurisdiction.

## 2. Goals

The revision should guarantee that:

1. Commonplace remains complete and useful without Cloudflare.
2. The reference implementation of log semantics is Elixir.
3. A Cloudflare Container behaves like an ordinary Commonplace BEAM server with a remote durable store.
4. TypeScript and other implementations can remain genuine protocol workalikes.
5. UUID logs remain independently addressable and synchronizable regardless of physical database layout.
6. The sidecar interface is coarse-grained enough that it does not turn every SQLite or CubDB operation into a network round trip.
7. Acknowledged writes survive Container sleep, crash, replacement, and rollout.
8. Existing SP1 and SP2 implementation work is retained.
9. Physical sharding can change later without changing the log protocol.

## 3. Non-goals

This proposal does not add:

- Merkle indexing;
- CRDT interpretation;
- a cross-writer total order;
- distributed Erlang between Cloudflare Containers;
- cross-log transactions;
- compaction or archival;
- a POSIX filesystem abstraction over Durable Object storage; or
- arbitrary untrusted SQL execution from a Container.

The existing version 0.1 exclusions remain exclusions.

## 4. Revised authority model

The word *authority* must be separated into three responsibilities:

| Responsibility | Owner |
| --- | --- |
| Definition of a valid entry | `Commonplace.Log.Entry` in Elixir |
| Classification of append, duplicate, gap, fork, and collision | `Commonplace.Log.Engine` in Elixir |
| Replica synchronization | `Commonplace.Log.Sync` in Elixir |
| Application acceptance, authorization, and interpretation | Commonplace BEAM application |
| Atomicity and durable acknowledgement | Persistence adapter and backing store |
| Stable Cloudflare realm identity and wakeup | Realm Container Durable Object |
| Pure edge implementation of the public protocol | Durable Object workalike |

SQLite constraints and triggers continue to defend storage invariants. They do not become the normative description of log semantics.

The canonical log remains the immutable set of compatible per-writer sequences identified by `log_id`. It is not identified with one particular Durable Object, SQLite file, or BEAM process.

## 5. Revised architecture

### 5.1 The Elixir reference stack

```text
Commonplace.LogStore             public log API
          |
Commonplace.Log.Engine            canonical semantics
  |       |        |
Entry   MergePlan  Sync
          |
Commonplace.Log.Persistence       durable-state port
     /                    \
LocalSQLite           CloudflareSidecar
```

The proposed responsibilities are:

#### `Commonplace.Log.Entry`

Owns version 1 entry validation, UUID and timestamp rules, canonical JSON, size limits, and canonical bytes. The existing Elixir module remains the reference.

#### `Commonplace.Log.MergePlan`

Pure Elixir classification of a validated batch against a read set. It returns either a typed domain error or an immutable commit plan. The current SP3 plan already proposes this module; the revision changes its status from a lockstep port of TypeScript to the normative implementation.

#### `Commonplace.Log.Engine`

Coordinates entry construction, validation, reads required for classification, optimistic commit, and retries. It contains no Exqlite, HTTP, Cloudflare, or CubDB code.

#### `Commonplace.Log.Sync`

Implements frontier/range synchronization over the public `LogStore` interface. The existing SP3 design remains appropriate.

#### `Commonplace.Log.Persistence`

A lower-level storage behavior used by the Engine. It does not decide whether a batch is a fork, gap, duplicate, or collision. It reads rows and applies an Elixir-authored commit plan atomically.

#### `Commonplace.LogStore`

Remains the public high-level behavior: create, append, merge, frontier, writer range, and local tail. It is implemented by composing the Engine with a persistence adapter. Callers do not need to know whether storage is local SQLite, CubDB, or a Cloudflare sidecar.

### 5.2 BEAM runtime topology

Within an active realm:

```text
Commonplace.Realm.Supervisor
  |
  +-- Commonplace.Realm.Persistence
  |
  +-- Commonplace.Log.Server <log UUID A>
  +-- Commonplace.Log.Server <log UUID B>
  +-- Commonplace.Log.Server <log UUID C>
  |
  +-- projectors, cells, agents, and mounts
```

One supervised process may exist for each active log. Inactive logs need no process. A restarted process reconstructs its state from persistence. The Durable Object is not duplicated at process granularity.

## 6. Persistence contract

The sidecar cannot execute an Elixir closure inside a SQLite transaction. The persistence boundary therefore uses optimistic read sets and declarative commit plans.

### 6.1 Read set

For append or merge, the Engine requests one coherent read set containing:

- log metadata and format version;
- the log's current persistence revision;
- tips for affected writers;
- rows occupying affected writer coordinates; and
- rows matching incoming entry IDs.

Illustrative shape:

```elixir
%Commonplace.Log.Persistence.ReadSet{
  log_id: log_id,
  revision: 41,
  tips: %{writer_id => %{seq: 27, entry_id: entry_id}},
  coordinates: %{{writer_id, 27} => canonical_bytes},
  entry_ids: %{entry_id => canonical_bytes}
}
```

### 6.2 Commit plan

After canonicalization and merge classification, the Engine submits:

```elixir
%Commonplace.Log.Persistence.CommitPlan{
  log_id: log_id,
  expected_revision: 41,
  insert_entries: [validated_entry_row, ...],
  put_tips: [new_tip, ...]
}
```

The adapter atomically:

1. checks that the log revision is still `41`;
2. inserts the exact canonical rows;
3. updates the exact tips supplied by the plan;
4. advances the revision to `42`; and
5. acknowledges only after commit.

If the revision changed, it returns `:stale_revision`. The Engine obtains a new read set, recomputes the plan, and retries. Constraint failures remain generic storage errors until the Engine rereads and classifies the resulting state.

This provides one read round trip and one commit round trip per logical batch. It avoids both a remote CubDB-call translation and Commonplace merge logic in the sidecar.

### 6.3 Proposed persistence behavior

The exact types may evolve, but the semantic boundary should resemble:

```elixir
defmodule Commonplace.Log.Persistence do
  @callback create_log(store(), log_id(), metadata()) ::
              :ok | {:error, term()}

  @callback read_set(store(), log_id(), read_query()) ::
              {:ok, ReadSet.t()} | {:error, term()}

  @callback commit(store(), CommitPlan.t()) ::
              {:ok, new_revision :: non_neg_integer()}
              | {:error, :stale_revision | term()}

  @callback frontier(store(), log_id()) :: {:ok, map()} | {:error, term()}
  @callback read_writer(store(), log_id(), writer_id(), keyword()) ::
              {:ok, map()} | {:error, term()}
  @callback tail_local(store(), log_id(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
```

This is deliberately log-shaped storage, not a second log implementation. It knows which rows to fetch and commit but does not know how those rows become a valid Commonplace history.

## 7. Storage layouts are implementation details

The current specification pins one exact DDL and assumes one physical database per log. The revised protocol should instead normatively pin invariants and query semantics. Individual adapters may use different physical layouts.

### 7.1 Existing local SQLite layout

The current Elixir schema and one-file-per-log plan remain valid for `Commonplace.Log.Persistence.LocalSQLite`:

```text
<data_dir>/<log_id>.sqlite3
```

SP3 Task 1 need not be discarded. Its schema becomes a reference adapter schema rather than the universal representation of a Commonplace log.

### 7.2 Realm sidecar layout

The managing Container Durable Object has one SQLite database for the realm, containing multiple logs:

```sql
CREATE TABLE logs (
  log_id         TEXT PRIMARY KEY,
  format_version INTEGER NOT NULL,
  revision       INTEGER NOT NULL DEFAULT 0,
  created_at     TEXT NOT NULL
) STRICT;

CREATE TABLE entries (
  arrival_seq    INTEGER PRIMARY KEY AUTOINCREMENT,
  log_id         TEXT NOT NULL,
  entry_id       TEXT NOT NULL,
  writer_id      TEXT NOT NULL,
  writer_seq     INTEGER NOT NULL,
  prev_entry_id  TEXT,
  created_at     TEXT NOT NULL,
  canonical_json BLOB NOT NULL,
  received_at_ms INTEGER NOT NULL,
  UNIQUE (log_id, entry_id),
  UNIQUE (log_id, writer_id, writer_seq)
) STRICT;

CREATE INDEX entries_by_log_writer
  ON entries (log_id, writer_id, writer_seq);

CREATE INDEX entries_by_log_arrival
  ON entries (log_id, arrival_seq);

CREATE TABLE writer_tips (
  log_id       TEXT NOT NULL,
  writer_id    TEXT NOT NULL,
  last_seq     INTEGER NOT NULL,
  last_entry_id TEXT NOT NULL,
  PRIMARY KEY (log_id, writer_id)
) STRICT;
```

The final adapter schema should retain the current immutability triggers, entry-size checks, foreign-key or audit coverage, and explicit transactional tests. This DDL is illustrative until reviewed against Cloudflare's supported SQLite subset.

### 7.3 Future sharding

One realm-sidecar database is the default, not a permanent limit. When a realm approaches storage or throughput limits, a placement directory can map a log UUID to a storage shard Durable Object:

```text
log UUID -> {realm managing DO | shard DO 7 | shard DO 12}
```

The Elixir Engine and public log protocol do not change. Per-log Durable Objects are one possible extreme of this mapping, not the foundational unit.

## 8. Cloudflare deployment

### 8.1 Request path

```text
client request
  -> wildcard Gateway Worker
  -> resolve authenticated realm_id
  -> get Container DO by realm_id
  -> forward HTTP to the BEAM release
```

Phoenix, Bandit, or a small Plug application inside the Container serves the Commonplace protocol and application APIs.

### 8.2 Storage path

```text
Commonplace.Log.Persistence.Cloudflare
  -> http://storage.internal/read-set or /commit
  -> Container outbound handler
  -> stub for this Container's managing DO
  -> ctx.storage.transactionSync + ctx.storage.sql
```

The outbound handler derives the realm from `containerId`; the BEAM request cannot select another client's realm. The storage hostname is internal and is not publicly routed.

The DO and Container are not guaranteed to be colocated, so read sets and commits must be batched. The adapter must never expose a remote analogue of individual `Sqlite3.step/2` calls.

### 8.3 Lifecycle

The Container filesystem is disposable. Every acknowledged mutation is already in Durable Object SQLite. On cold start, rollout, crash, or migration:

1. a fresh BEAM release boots;
2. the realm supervisor starts;
3. active log processes reconstruct on demand; and
4. pending durable inbox work is redelivered.

The managing DO may eventually provide a durable inbox/outbox and wakeup mechanism, but that is a separate layer from version 0.1 log correctness.

## 9. Disposition of existing repository work

The revision should preserve rather than erase the current implementation.

| Existing path or work | Disposition |
| --- | --- |
| `conformance/` | Keep. It becomes the language-neutral protocol contract. Add persistence-plan fixtures separately. |
| `commonplace_log/lib/commonplace/log/entry.ex` | Keep and designate normative. |
| `commonplace_log/lib/commonplace/log/jcs.ex` | Keep and designate normative. |
| `commonplace_log/lib/commonplace/log_store.ex` | Keep the public surface; revise its documentation and implement it through Engine + Persistence. |
| `commonplace_log/lib/commonplace/log_store/sqlite/schema.ex` | Keep for the local one-file-per-log adapter; stop describing it as the universal DDL or TypeScript twin. |
| Planned Elixir `MergePlan` and `Sync` | Continue, but make Elixir normative instead of a lockstep port. |
| `worker/src/do/*` | Keep as the complete Durable Object workalike. Freeze SP2 as a successful conformance milestone. |
| `worker/src/entry.ts`, `jcs.ts`, `merge-plan.ts` | Keep as independent workalike semantics checked by shared vectors, not normative twins. |
| `worker/src/do/http.ts` | Keep as the public protocol of the workalike; it is not the BEAM sidecar API. |
| SP2 plan and ledger | Preserve as historical implementation record. |
| Current SP3 plan | Amend before continuing beyond Task 1. Most tasks remain useful; authority and lockstep language changes. |
| Planned SP4 `LogStore.Cloudflare` | Split into `Persistence.CloudflareSidecar` and, optionally, `LogStore.WorkalikeClient`. |

The existing TypeScript implementation has two durable roles:

1. a lightweight Commonplace-compatible edge node that can operate without BEAM; and
2. an independent implementation that proves the protocol is not accidentally defined by Elixir internals.

It should not be reused as the BEAM storage sidecar by merely placing the BEAM Container in front of its log-specific HTTP API. The new sidecar must not import entry canonicalization or merge-classification modules.

## 10. Repository organization

Keep the polyglot repository during the transition, but make the roles explicit:

```text
commonplace-log/
  commonplace_log/          # normative Elixir library and reference server
  conformance/              # language-neutral protocol fixtures
  worker/                   # complete Durable Object workalike
  cloudflare_sidecar/       # Realm Container DO + mechanical persistence API
  docs/
    protocol/               # normative platform-neutral specification
    deployments/            # Cloudflare BEAM realm deployment
    proposals/              # architecture decisions and migrations
    superpowers/plans/       # execution plans and historical ledgers
```

Renaming `worker/` is optional and can be deferred to avoid churn. The root README should make the Elixir reference status obvious even while the workalike contains more code.

## 11. Revised implementation plan

### Phase 0: record the architectural amendment

1. Add this proposal to `docs/proposals/`.
2. Amend the version 0.1 specification so protocol invariants are normative and physical DDL is adapter-specific.
3. Mark SP2 complete as the Durable Object workalike milestone.
4. Amend SP3 before beginning Task 2.
5. Replace the old SP4 description.

### Phase 1: finish the BEAM-native engine

1. Implement `Commonplace.Log.MergePlan` in Elixir.
2. Remove lockstep-source wording; verify behavior through shared fixtures.
3. Introduce `Commonplace.Log.Engine` and plan/read-set types.
4. Implement `Commonplace.Log.Sync` in Elixir.
5. Keep property tests and cross-runtime conformance.

### Phase 2: complete local persistence

1. Complete the existing one-file-per-log SQLite adapter.
2. Put all domain decisions in the Engine.
3. Make the SQLite adapter read state and atomically apply commit plans.
4. Verify process restart, clone/rekey behavior, writer locking, and sync between local replicas.

### Phase 3: build the Cloudflare realm sidecar

1. Add a `RealmContainer` class extending Cloudflare's Container class.
2. Add the multi-log realm schema and per-log revision.
3. Implement internal read-set, commit-plan, frontier, range, and tail operations.
4. Implement optimistic revision checks with `transactionSync`.
5. Add the Container outbound handler for `storage.internal`.
6. Implement `Commonplace.Log.Persistence.CloudflareSidecar` in Elixir.
7. Run the same Engine tests over local SQLite and the sidecar.

### Phase 4: deploy one complete BEAM realm

1. Route one test subdomain to one named realm Container.
2. Boot a minimal Commonplace release.
3. Create and sync multiple UUID logs in the realm database.
4. Force sleep, restart, and image rollout.
5. Verify that acknowledged state reconstructs and writer identity remains correct.
6. Measure cold-start time, BEAM memory, read-set latency, commit latency, and batch throughput.

### Phase 5: retain and exercise the workalike

1. Keep the existing pure Durable Object implementation green against protocol conformance.
2. Add an Elixir `WorkalikeClient` only if a deployment needs direct sync with it.
3. Demonstrate BEAM reference replica to DO workalike convergence.

## 12. Test strategy

Testing divides into three contracts.

### Protocol conformance

Applies to the Elixir reference implementation and every workalike:

- canonical JSON vectors;
- entry validation;
- merge laws;
- gap, fork, and collision behavior;
- frontier/range synchronization; and
- wire-level errors.

### Persistence conformance

Applies to LocalSQLite and CloudflareSidecar:

- coherent read sets;
- expected-revision commit;
- stale-revision rejection;
- all-or-nothing plan application;
- immutability;
- restart durability;
- paging and local-arrival cursors; and
- storage-full behavior.

### Deployment conformance

Applies to the Cloudflare BEAM realm:

- tenant routing isolation;
- sidecar scope injection;
- Container sleep and wake;
- rollout replacement;
- no correctness dependency on Container disk;
- bounded storage round trips per batch; and
- reconstruction of active log processes.

## 13. Acceptance criteria

The revision is successful when:

1. The Elixir test suite is the normative source for entry and merge semantics.
2. Deleting or disabling `worker/` does not make the Elixir implementation incomplete.
3. The DO workalike still passes protocol conformance independently.
4. The Cloudflare sidecar has no dependency on JCS, entry validation, or merge-classification modules.
5. A BEAM process produces the same domain error for LocalSQLite and CloudflareSidecar.
6. One Cloudflare realm stores and serves multiple UUID logs.
7. Each logical batch requires at most one sidecar read-set request and one commit request, excluding stale-revision retries.
8. No acknowledged entry is lost across Container sleep, crash, or rollout.
9. Per-log Durable Object sharding can be introduced only by changing persistence placement.
10. Commonplace remains a BEAM-native system with a documented workalike protocol.

## 14. Risks and mitigations

### Optimistic transaction complexity

The sidecar cannot run Elixir code inside its SQLite transaction. Read-set plus expected-revision commit adds retry logic.

**Mitigation:** Make the Engine's retry loop explicit and property-test it under injected concurrent revisions. Use a per-log revision so unrelated logs do not cause retries.

### Sidecar boundary becomes secretly semantic

A convenient endpoint such as `POST /merge` could gradually reintroduce TypeScript ownership of the log.

**Mitigation:** The sidecar may return only persistence errors such as `stale_revision`, `constraint_violation`, and `storage_full`. Domain errors such as `writer_fork` must originate in Elixir. Enforce a dependency test preventing sidecar imports from workalike entry and merge modules.

### Remote storage latency

Cloudflare does not guarantee that the managing DO and Container share a location.

**Mitigation:** Batch read sets and commits, keep reconstructed state in BEAM processes and ETS, page large reads, and benchmark before committing to the deployment as the default production host.

### Realm database size and contention

One realm database is capped by Durable Object storage and serializes writes.

**Mitigation:** This matches the first target of small client realms. Add storage-shard placement by UUID when measurements justify it.

### Two complete implementations remain

Elixir and the DO workalike can drift.

**Mitigation:** Shared vectors and black-box conformance define compatibility. Do not require source-level lockstep; require observable protocol equivalence.

## 15. Consequences

The revised architecture is more explicitly BEAM-native but slightly more complex than making the Durable Object the complete log service. It introduces an Engine/Persistence split and an optimistic commit protocol. In exchange:

- Commonplace's foundational semantics have one normative home;
- the Cloudflare deployment still gains stable routing, scale-to-zero, durable SQLite, and lifecycle management;
- small workalikes remain possible without shipping BEAM;
- BEAM processes retain their natural fine-grained role;
- Durable Objects occupy an appropriately coarse durability boundary; and
- physical database topology becomes replaceable rather than architectural destiny.

The short version is:

> `commonplace-log` is an Elixir protocol and reference engine. A Cloudflare Container runs that engine as a BEAM server. Its managing Durable Object is the server's durable SQLite sidecar. The existing pure Durable Object implementation is a conforming workalike, not the definition of Commonplace.

## References

- [`commonplace-log` current specification](https://github.com/commonplace-systems/commonplace-log/blob/main/docs/commonplace-monotonic-log-spec.md)
- [`commonplace-log` SP2 Durable Object plan](https://github.com/commonplace-systems/commonplace-log/blob/main/docs/superpowers/plans/2026-08-22-sp2-durable-object.md)
- [`commonplace-log` SP3 Elixir store and sync plan](https://github.com/commonplace-systems/commonplace-log/blob/main/docs/superpowers/plans/2026-08-22-sp3-elixir-store-sync.md)
- [Cloudflare Container interface](https://developers.cloudflare.com/containers/container-class/)
- [Cloudflare Container lifecycle](https://developers.cloudflare.com/containers/platform-details/architecture/)
- [Cloudflare Containers: connect to Workers bindings](https://developers.cloudflare.com/containers/platform-details/workers-connections/)
- [Cloudflare SQLite-backed Durable Object storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
- [Cloudflare Durable Object limits](https://developers.cloudflare.com/durable-objects/platform/limits/)
