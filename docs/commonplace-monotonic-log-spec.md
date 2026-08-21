# Commonplace Monotonic Log

**Version:** 0.1-draft

**Date:** 2026-08-21

**Status:** Proposed implementation specification

## 1. Decision

A Commonplace log is a logical object identified by a UUID. A writable replica does not append into one shared global sequence. Instead, each writer owns one append-only sequence, and a log is the union of those writer sequences.

On Cloudflare, each log is stored in one SQLite-backed Durable Object. On an ordinary Elixir host, the same interface is backed by local SQLite. An Elixir process running in a Cloudflare Container accesses the Durable Object through an internal HTTP bridge; the Container filesystem is only a cache and is never authoritative.

Replicas merge by taking the longer compatible prefix of each writer sequence. The merge is monotonic, associative, commutative, and idempotent for valid replicas. There is no global event order, consensus protocol, Merkle tree, or CRDT interpretation in this version.

In this specification, **canonical** means that all replicas agree on the immutable entries belonging to a log. It does not mean that concurrent entries have a canonical total order. The Cloudflare Durable Object may be the designated online authority replica, but its local arrival order is not portable log semantics.

## 2. Scope

This specification defines:

- logical log and entry identities;
- the single-writer sequence rule;
- immutable JSON entry encoding;
- monotonic replica merge;
- frontier and range-based synchronization;
- the required storage interface;
- SQLite schema and transaction behavior;
- the Cloudflare Durable Object deployment target; and
- the Elixir-facing adapter boundary.

It deliberately does not define:

- Merkle trees, content-addressed entry IDs, or anti-entropy by hashes;
- application-level CRDTs or state reducers;
- a total order across writers;
- leader election or consensus;
- deletion, compaction, archival, or retention;
- capabilities, signatures, or writer-key rotation;
- cross-log transactions; or
- large-blob storage beyond an application-level reference.

## 3. Normative language

The terms **MUST**, **MUST NOT**, **SHOULD**, **SHOULD NOT**, and **MAY** are normative.

## 4. Vocabulary

**Log:** A logical append-only collection identified by `log_id`.

**Replica:** A physical copy of some or all writer sequences for a log. Version 0.1 replicas store complete prefixes, not sparse sequences.

**Writer:** An append authority identified by `writer_id`. At most one live process may append as a given writer for a given log.

**Writer sequence:** The entries produced by one writer for one log, numbered from 1 without gaps.

**Entry:** An immutable JSON object with a UUID, writer coordinate, predecessor UUID, timestamp, and application body.

**Frontier:** For every writer known to a replica, the sequence number and entry UUID at the tip of that writer's stored prefix.

**Authority replica:** The online Cloudflare copy to which clients normally push and from which they normally pull. Authority is an operational role, not a different data model.

**Arrival sequence:** A local database cursor assigned when an entry reaches one replica. It is useful for projections and notifications but MUST NOT be synchronized or treated as semantic order.

## 5. Abstract model

For a log `L`, replica state is a finite map from writer UUID to a finite entry sequence:

```text
L = {
  writer_a -> [a1, a2, ... an],
  writer_b -> [b1, b2, ... bm],
  ...
}
```

Each sequence starts at 1 and contains no gaps. Entry `n` names entry `n-1` as its predecessor. Sequences from different writers have no order relative to one another.

Define `A <= B` when every writer sequence in `A` is a prefix of the corresponding sequence in `B`. Two replicas are compatible when, for every writer, one stored sequence is a prefix of the other. Their merge is the pointwise longer sequence:

```text
(A merge B)[writer] = longer(A[writer], B[writer])
```

For compatible states:

```text
A merge A = A
A merge B = B merge A
(A merge B) merge C = A merge (B merge C)
A <= A merge B
B <= A merge B
```

If two sequences contain different entries at the same `(writer_id, writer_seq)`, they are not compatible. This is a **writer fork**, not an ordinary concurrent update. Version 0.1 reports and stops at the fork; it does not choose a winner.

Concurrent writes are valid only when they use different writer IDs.

## 6. Identities

### 6.1 Log identity

`log_id` MUST be a UUID represented as a lowercase canonical UUID string. It identifies the logical log across every replica and storage backend.

The physical Cloudflare address MAY additionally contain a deployment or realm scope. The recommended Durable Object name is:

```text
<scope_id>:<log_id>
```

If a Durable Object namespace or Worker deployment is already dedicated to one realm, its object name MAY be only `<log_id>`. `scope_id` is physical isolation metadata and is not part of logical log identity.

### 6.2 Writer identity

`writer_id` MUST be a UUID. A writer sequence is scoped by `(log_id, writer_id)`.

A replica MUST hold an exclusive local lock before appending under a persistent writer ID. If a database is cloned, restored while the original remains active, or otherwise loses exclusive writer continuity, the new writable instance MUST generate a new writer ID before appending.

A writer ID SHOULD be an installation or process-incarnation identity rather than a human or tenant identity. Ordinary restarts MAY retain it when exclusive access to the same durable local database is guaranteed.

### 6.3 Entry identity

`entry_id` MUST be a UUID generated before the first storage or network attempt. UUIDv7 is recommended for operational readability, but UUID ordering has no protocol meaning.

An `entry_id` MUST identify exactly one canonical entry within a log. Reuse with different bytes is an entry-ID collision and MUST be rejected.

## 7. Entry format

Every entry has this shape:

```json
{
  "version": 1,
  "log_id": "0198cc6e-47ac-7d72-93db-b6fbd92bfca2",
  "entry_id": "0198cc70-3800-75bd-b56a-5f913fbdeed3",
  "writer_id": "fab4e8a5-ce9e-48d0-8f78-1d312b978207",
  "writer_seq": 27,
  "prev_entry_id": "0198cc6f-f11c-7803-aa25-401bc5f781c0",
  "created_at": "2026-08-21T20:14:03.291Z",
  "body": {
    "type": "commonplace.example",
    "value": "hello"
  }
}
```

The fields are defined as follows:

| Field | Requirement |
| --- | --- |
| `version` | Integer `1`. |
| `log_id` | Canonical UUID matching the target log. |
| `entry_id` | Canonical UUID unique within the log. |
| `writer_id` | Canonical UUID naming the writer sequence. |
| `writer_seq` | Positive integer. The first entry is `1`; each later entry increments by exactly one. |
| `prev_entry_id` | `null` when `writer_seq` is `1`; otherwise the `entry_id` at `writer_seq - 1` in the same writer sequence. |
| `created_at` | UTC RFC 3339 timestamp. Advisory only; never used to resolve order or conflict. |
| `body` | Application-owned JSON object. The log layer does not interpret it. |

No additional top-level fields are permitted in version 1. Extensions belong inside `body` or require a new entry version.

### 7.1 Canonical JSON

Before storage or comparison, an entry MUST be encoded using the JSON Canonicalization Scheme in RFC 8785. Input MUST satisfy I-JSON constraints:

- object keys are unique;
- strings are valid Unicode;
- numbers are finite;
- integers outside `-(2^53 - 1)` through `2^53 - 1` are represented as strings; and
- UUIDs and timestamps use the forms required above.

Canonicalization exists so JavaScript and Elixir compare the same immutable bytes. It is not a Merkle construction and the entry ID is not derived from those bytes.

The complete canonical entry MUST be no larger than 1 MiB. Larger content MUST be stored outside the log, such as in R2, and represented by a small immutable reference in `body`.

## 8. Required invariants

Every conforming store MUST preserve these invariants:

1. A committed entry is never updated or deleted.
2. Acknowledgement occurs only after durable transaction commit.
3. `(writer_id, writer_seq)` names at most one entry.
4. `entry_id` names at most one canonical entry.
5. Every stored writer sequence is a complete prefix beginning at 1.
6. Entry 1 has `prev_entry_id = null`.
7. Entry `n > 1` names entry `n - 1` in `prev_entry_id`.
8. `log_id` in the entry matches the target log.
9. Retrying an identical append or merge is a successful no-op.
10. A failed batch leaves no partial writes.
11. Local metadata such as arrival order and receipt time never changes entry identity or merge semantics.
12. Application deletion is represented by appending an application-level tombstone entry, not by removing log history.

## 9. Store operations

A backend MUST implement the following semantic operations. Function names are illustrative.

### 9.1 `create_log(log_id)`

Creates log metadata and storage schema. The operation is idempotent. Reusing a physical store for a different `log_id` MUST fail with `log_mismatch`.

### 9.2 `append(log_id, writer_id, body, created_at)`

Atomically:

1. reads the local tip for `writer_id`;
2. allocates `writer_seq = tip.seq + 1`;
3. generates an `entry_id`;
4. sets `prev_entry_id` to the current tip UUID, or `null` for entry 1;
5. canonicalizes and validates the entry;
6. inserts the entry;
7. updates the writer tip; and
8. assigns local arrival metadata.

Sequence allocation and entry insertion MUST occur in the same transaction. Only the process holding the writer's exclusive lock may call this operation.

### 9.3 `merge(log_id, entries)`

Validates and inserts a batch received from another replica. The batch is atomic.

For each writer represented in the batch, the store MUST:

1. sort entries by `writer_seq`;
2. accept exact duplicates as already present;
3. require the first new entry to be exactly one after the current local tip;
4. require its `prev_entry_id` to equal the local tip UUID;
5. require every subsequent entry to increment by one and name the preceding batch entry; and
6. update the writer tip only after all entries validate.

An entry beyond the next expected sequence returns `writer_gap` and includes the receiver's current tip. A different entry at an occupied writer coordinate returns `writer_fork`. An existing `entry_id` with different canonical bytes returns `entry_id_collision`.

### 9.4 `frontier(log_id)`

Returns one tip for every known writer:

```json
{
  "log_id": "0198cc6e-47ac-7d72-93db-b6fbd92bfca2",
  "writers": [
    {
      "writer_id": "fab4e8a5-ce9e-48d0-8f78-1d312b978207",
      "seq": 27,
      "entry_id": "0198cc70-3800-75bd-b56a-5f913fbdeed3"
    }
  ]
}
```

Writers with no entries are omitted. Frontier entries MUST be sorted by `writer_id` in encoded responses so results are stable.

### 9.5 `read_writer(log_id, writer_id, after_seq, through_seq, limit)`

Returns canonical entries for one writer in ascending `writer_seq` order. The range is exclusive of `after_seq` and inclusive of `through_seq`.

The result MUST contain a complete contiguous range unless limited by `limit`. It returns a continuation cursor when more entries remain.

### 9.6 `tail_local(log_id, after_arrival_seq, limit)`

Returns entries in this replica's arrival order. This supports projectors, subscribers, and debugging. The cursor and order are explicitly replica-local and MUST NOT be used for synchronization or equality.

## 10. Replica synchronization

Synchronization uses frontier exchange and writer-range transfer.

For replicas `A` and `B`:

1. Exchange frontiers.
2. For each writer present on either side, compare `(seq, entry_id)`.
3. If sequence numbers are equal and nonzero, entry IDs MUST match. Otherwise report `writer_fork`.
4. If `A` is shorter, `A` requests from `B` the range after `A`'s tip through `B`'s advertised tip. The first received entry must name `A`'s tip in `prev_entry_id`.
5. If `B` is shorter, perform the symmetric transfer.
6. Merge pages atomically and idempotently.
7. Exchange frontiers again. Stop when they are equal or when a caller-defined synchronization deadline is reached.

Pseudocode for one direction:

```text
remote_frontier = remote.frontier(log_id)
local_frontier  = local.frontier(log_id)

for each writer in remote_frontier:
  local_tip  = local_frontier.get(writer, seq=0, entry_id=null)
  remote_tip = remote_frontier[writer]

  if local_tip.seq == remote_tip.seq:
    assert local_tip.entry_id == remote_tip.entry_id

  if local_tip.seq < remote_tip.seq:
    cursor = local_tip.seq
    while cursor < remote_tip.seq:
      page = remote.read_writer(
        writer,
        after_seq=cursor,
        through_seq=remote_tip.seq
      )
      local.merge(page.entries)
      cursor = page.last_seq
```

The protocol does not need distributed locking because different writers may advance concurrently. A sync pass observes a snapshot frontier, transfers only through that frontier, and then repeats if newer entries appeared.

Frontier equality is an efficient equality test only for valid replicas that obey the single-writer rule and immutable entry-ID rule. Version 0.1 does not prove historical equality after arbitrary corruption or malicious ID reuse. A future hash-based inventory can add that proof without changing the storage model.

## 11. HTTP protocol

The Cloudflare adapter exposes an internal versioned HTTP interface. The public gateway MAY expose the same semantics after authentication, but raw Durable Objects MUST NOT be directly public.

### 11.1 Create

```http
PUT /v1/logs/{log_id}
Content-Type: application/json

{"version":1}
```

Success is `200 OK` whether the log was created or already existed.

### 11.2 Merge entries

```http
POST /v1/logs/{log_id}/entries
Content-Type: application/json

{"entries":[ ...canonical entry objects... ]}
```

The default limits are 100 entries and 4 MiB of canonical entry bytes per batch. Servers MAY advertise lower limits but MUST support single-entry requests up to the 1 MiB entry limit.

Success:

```json
{
  "inserted": 12,
  "present": 3,
  "frontier": {
    "writers": [
      {
        "writer_id": "fab4e8a5-ce9e-48d0-8f78-1d312b978207",
        "seq": 27,
        "entry_id": "0198cc70-3800-75bd-b56a-5f913fbdeed3"
      }
    ]
  }
}
```

### 11.3 Read frontier

```http
GET /v1/logs/{log_id}/frontier
```

### 11.4 Read writer range

```http
GET /v1/logs/{log_id}/writers/{writer_id}/entries?after=12&through=47&limit=100
```

### 11.5 Read local arrival tail

```http
GET /v1/logs/{log_id}/entries?after_arrival=900&limit=100
```

### 11.6 Errors

Errors use this envelope:

```json
{
  "error": {
    "code": "writer_gap",
    "message": "expected writer sequence 28",
    "details": {
      "writer_id": "fab4e8a5-ce9e-48d0-8f78-1d312b978207",
      "expected_seq": 28,
      "tip_entry_id": "0198cc70-3800-75bd-b56a-5f913fbdeed3"
    }
  }
}
```

| Status | Code | Meaning |
| --- | --- | --- |
| `400` | `invalid_json` | Request is not valid JSON. |
| `401` | `unauthenticated` | No valid caller identity. |
| `403` | `unauthorized` | Caller cannot access this scope or log. |
| `404` | `log_not_found` | Log has not been provisioned. |
| `409` | `log_mismatch` | Physical store belongs to another log. |
| `409` | `writer_gap` | A required predecessor is missing. |
| `409` | `writer_fork` | One writer coordinate contains different entries. |
| `409` | `entry_id_collision` | One entry UUID names different bytes. |
| `413` | `entry_too_large` or `batch_too_large` | Size limit exceeded. |
| `422` | `invalid_entry` | Entry violates the version 1 format. |
| `507` | `storage_full` | Store cannot durably accept more entries. |

Clients MAY retry timeouts, `429`, and `5xx` responses with exponential backoff and jitter. They MUST reuse the same entry objects on retry.

## 12. SQLite storage layout

The authoritative Cloudflare backend and the preferred local Elixir backend use this logical schema:

```sql
CREATE TABLE IF NOT EXISTS log_meta (
  singleton      INTEGER PRIMARY KEY CHECK (singleton = 1),
  log_id         TEXT NOT NULL,
  format_version INTEGER NOT NULL CHECK (format_version = 1),
  created_at     TEXT NOT NULL
) STRICT;

CREATE TABLE IF NOT EXISTS entries (
  arrival_seq    INTEGER PRIMARY KEY AUTOINCREMENT,
  entry_id       TEXT NOT NULL UNIQUE,
  writer_id      TEXT NOT NULL,
  writer_seq     INTEGER NOT NULL CHECK (writer_seq > 0),
  prev_entry_id  TEXT,
  created_at     TEXT NOT NULL,
  canonical_json BLOB NOT NULL CHECK (length(canonical_json) <= 1048576),
  received_at_ms INTEGER NOT NULL,
  UNIQUE (writer_id, writer_seq)
) STRICT;

CREATE INDEX IF NOT EXISTS entries_by_writer
  ON entries (writer_id, writer_seq);

CREATE TABLE IF NOT EXISTS writer_tips (
  writer_id    TEXT PRIMARY KEY,
  last_seq     INTEGER NOT NULL CHECK (last_seq > 0),
  last_entry_id TEXT NOT NULL
) STRICT;
```

`log_id` is omitted from each row because one physical database stores one logical log. It remains inside `canonical_json`, and every insertion verifies it against `log_meta`.

`received_at_ms` and `arrival_seq` are local metadata. They are not included in exports, frontier comparison, or entry equality.

### 12.1 Transaction algorithm

For a merge batch, one transaction MUST:

1. validate and canonicalize the entire batch;
2. detect duplicate `entry_id` values and writer coordinates within the batch;
3. load affected writer tips;
4. compare any entries already present;
5. validate every new writer suffix and predecessor link;
6. insert all new entries; and
7. update all affected writer tips.

Any exception rolls the entire batch back.

In a SQLite-backed Durable Object, this is implemented with `ctx.storage.transactionSync(...)` and synchronous `ctx.storage.sql.exec(...)` statements. In local SQLite, use an explicit write transaction. A local durable deployment SHOULD use `PRAGMA synchronous = FULL`; WAL mode MAY be used for reader concurrency.

## 13. Cloudflare deployment

### 13.1 Topology

```text
<tenant>.commonplace.st
          |
          v
  wildcard Gateway Worker
          |
          v
 named tenant Container (BEAM)
          |
          | HTTP to logs.internal
          v
 Container outbound handler
          |
          v
 Log Durable Object namespace
          |
          v
 one SQLite database per (scope_id, log_id)
```

The Gateway Worker resolves the tenant subdomain to an immutable `scope_id`, authenticates the request, and routes to the tenant's named Container or directly to a log Durable Object when BEAM participation is unnecessary.

The BEAM Container calls a virtual internal hostname such as `http://logs.internal`. A Container outbound handler intercepts that request, injects the caller's scope, verifies authorization, computes the Durable Object ID, and invokes the object. The Elixir release needs only an HTTP client, not a Cloudflare SDK.

The Durable Object ID is derived with `idFromName("<scope_id>:<log_id>")`, unless the deployment is already physically tenant-scoped. The Durable Object stores and verifies `log_id` on creation so a routing bug cannot silently reuse a database for another logical log.

### 13.2 Storage choices

| Component | Target | Reason |
| --- | --- | --- |
| Canonical log | SQLite-backed Durable Object | Per-log serialization, strong consistency, private transactional storage, and natural UUID routing. |
| BEAM local cache | Container memory or ephemeral disk | Performance only; safe to lose at any time. |
| Large immutable bodies | R2, referenced from an entry | Durable object rows remain small. |
| Traditional-host replica | SQLite via an Elixir adapter | Same transactions and schema as the cloud model. |
| Existing Commonplace replica | CubDB adapter, temporarily | Acceptable if it enforces the same protocol invariants. |

D1 is not the default because this protocol does not need cross-log SQL queries and benefits from one serialized storage authority per log. R2 is not the log database because it does not provide the required small transactional append and tip update. A CubDB file on Container disk is not authoritative because Container disk is ephemeral.

### 13.3 Limits

Cloudflare currently limits a SQLite-backed Durable Object to 10 GB and a SQL row, string, or BLOB to 2 MB on paid plans. This protocol's 1 MiB entry cap leaves encoding and index headroom. Implementations SHOULD alert well before a log reaches its object storage limit.

Version 0.1 has no compaction. Logs expected to approach the per-object limit need a later archival or checkpoint specification; deleting history ad hoc is non-conforming.

## 14. Elixir interface

The application depends on a behavior rather than directly on CubDB, SQLite, or HTTP:

```elixir
defmodule Commonplace.LogStore do
  @callback create_log(log_id :: Ecto.UUID.t()) :: :ok | {:error, term()}

  @callback append(
              log_id :: Ecto.UUID.t(),
              writer_id :: Ecto.UUID.t(),
              body :: map(),
              created_at :: DateTime.t()
            ) :: {:ok, map()} | {:error, term()}

  @callback merge(log_id :: Ecto.UUID.t(), entries :: [map()]) ::
              {:ok, map()} | {:error, term()}

  @callback frontier(log_id :: Ecto.UUID.t()) ::
              {:ok, map()} | {:error, term()}

  @callback read_writer(
              log_id :: Ecto.UUID.t(),
              writer_id :: Ecto.UUID.t(),
              keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback tail_local(log_id :: Ecto.UUID.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
```

Recommended adapters:

- `Commonplace.LogStore.SQLite` for a host with durable local disk;
- `Commonplace.LogStore.Cloudflare` for HTTP access from a BEAM Container; and
- `Commonplace.LogStore.CubDB` as a migration adapter for the existing system.

Canonical JSON conformance vectors MUST be shared between the TypeScript Durable Object and Elixir adapters. An entry created in either runtime must produce identical canonical bytes in the other.

The Cloudflare adapter SHOULD pool HTTP connections, page range reads, retry idempotent operations, and expose backpressure rather than buffering without bound. It MUST NOT report a successful append before the Durable Object acknowledges commit.

## 15. Failure semantics

### 15.1 Lost acknowledgement

If commit succeeds but the response is lost, the client retries the identical entry. The store returns it as already present. No duplicate is created.

### 15.2 Process or object restart

All correctness state is in SQLite. In-memory tips, subscriptions, and caches may disappear. On restart they are reconstructed from `writer_tips` and `entries`.

### 15.3 Network partition

Different writers may append independently. When connectivity returns, their sequences merge without conflict. No wall-clock comparison is involved.

### 15.4 Cloned writer identity

If two live replicas append as the same `(log_id, writer_id)`, they may fork. Sync returns `writer_fork` and stops that writer. Operators preserve both copies for diagnosis, choose an application-level recovery, and resume future work under a fresh writer ID. The storage layer MUST NOT silently choose one branch.

### 15.5 Missing predecessor

The receiver rejects the batch with `writer_gap` and its current tip. The sender restarts transfer immediately after that tip.

### 15.6 Storage exhaustion

The transaction fails without a partial batch. The service returns `507 storage_full`, raises an operational alert, and remains readable.

### 15.7 Clock skew

Clock skew changes only advisory `created_at` values. It cannot affect append position, frontier, merge, or conflict handling.

## 16. Security boundary

The raw log protocol assumes an authenticated, authorized transport. Deployment MUST enforce:

- the caller is permitted to access `scope_id` and `log_id`;
- a Container cannot select another tenant's scope merely by changing a hostname or request body;
- entry `log_id` matches the authorized path;
- request and batch size limits are enforced before expensive parsing;
- raw Durable Object stubs are not exposed to untrusted callers; and
- secrets are never placed in replicated entry bodies. Entries contain secret references only.

Writer signatures and capability proofs can be added above this store. Until then, a receiving authority trusts its authenticated peer to submit entries for the stated writer.

## 17. Observability

Each store SHOULD report:

- log and scope identifiers;
- inserted and duplicate entry counts;
- entries and bytes stored;
- writer count and frontier size;
- merge batch size and latency;
- `writer_gap`, `writer_fork`, and collision counts;
- storage-full and transaction-failure counts;
- synchronization lag by writer; and
- the local arrival cursor processed by each projector.

Logs and metrics MUST NOT include full entry bodies by default.

## 18. Conformance tests

An implementation is conforming only if it passes at least these tests:

1. Repeating one append produces one stored entry.
2. Retrying after a simulated lost acknowledgement is idempotent.
3. Two replicas appending under different writer IDs converge in either sync order.
4. Three-way merge is associative for compatible replicas.
5. A shorter writer prefix extends to the longer prefix page by page.
6. A missing sequence is rejected without partial insertion.
7. A predecessor mismatch is reported as a writer fork.
8. Different entries at one writer coordinate are rejected.
9. Reusing an entry UUID with different bytes is rejected.
10. A mixed-writer batch either commits completely or not at all.
11. Local arrival order may differ while frontiers and canonical entries converge.
12. Timestamps do not affect merge results.
13. Elixir and JavaScript produce identical canonical JSON for shared fixtures.
14. Restarting or replacing a BEAM Container loses no acknowledged log entries.
15. One tenant scope cannot address another tenant's physical log object.

Property tests SHOULD generate random writer sequences, partitions, batch boundaries, duplicate deliveries, and synchronization orders, then verify the merge laws in Section 5.

## 19. Initial implementation plan

### Phase 1: storage authority

- Implement the `CommonplaceLog` SQLite-backed Durable Object.
- Add schema initialization, transactional batch merge, frontier, writer range, and local tail endpoints.
- Add canonical JSON fixtures and merge-law property tests.

### Phase 2: BEAM access

- Implement the Container outbound handler for `logs.internal`.
- Implement `Commonplace.LogStore.Cloudflare`.
- Keep all Container-local log state disposable.

### Phase 3: local replica and sync

- Implement `Commonplace.LogStore.SQLite` on normal hosts.
- Add writer identity locking and clone/rekey behavior.
- Implement bidirectional frontier/range synchronization.

### Phase 4: integration

- Put existing Commonplace commit or cell events inside `body` without teaching the log store their meaning.
- Run the new store beside the current CommitStore and compare exported histories.
- Move one small log or cell at a time.

WebSocket wakeups, projections, Merkle inventories, CRDT reduction, retention, and cross-log composition remain subsequent layers.

## 20. Acceptance criteria

Version 0.1 is ready when:

- a local Elixir replica can append while disconnected;
- a Cloudflare-hosted BEAM instance can append through the internal bridge;
- both replicas converge after bidirectional sync regardless of delivery order or retries;
- acknowledged entries survive Container and Durable Object restarts;
- no code path writes canonical data to Container disk;
- same-writer divergence fails loudly rather than choosing a winner;
- the store exposes no global order other than explicitly local arrival order; and
- application code interacts only through the `LogStore` behavior.

## 21. References

- [Cloudflare: What are Durable Objects?](https://developers.cloudflare.com/durable-objects/concepts/what-are-durable-objects/)
- [Cloudflare: SQLite-backed Durable Object Storage](https://developers.cloudflare.com/durable-objects/api/sqlite-storage-api/)
- [Cloudflare: Durable Object limits](https://developers.cloudflare.com/durable-objects/platform/limits/)
- [Cloudflare: Connect Containers to Workers bindings](https://developers.cloudflare.com/containers/platform-details/workers-connections/)
- [Cloudflare: Container architecture and lifecycle](https://developers.cloudflare.com/containers/platform-details/architecture/)
- [RFC 8785: JSON Canonicalization Scheme](https://www.rfc-editor.org/rfc/rfc8785)
- [SQLite: synchronous pragma](https://www.sqlite.org/pragma.html#pragma_synchronous)
- [Exqlite documentation](https://hexdocs.pm/exqlite/Exqlite.html)
