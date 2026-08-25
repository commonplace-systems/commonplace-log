# Commonplace Monotonic Log

An append-only log that several parties can write to, replicate, and merge
without a leader, a consensus protocol, or a CRDT — and that refuses to guess
when something has gone wrong.

The design rests on one rule: **every writer owns its own sequence, numbered
1, 2, 3… with no gaps, and a log is the union of those sequences.** Because a
writer's own sequence is totally ordered and nobody else may extend it, two
replicas of the same log can always be merged by a pointwise rule — for each
writer, keep the longer of the two prefixes. That merge is idempotent,
commutative, and associative, so replicas converge no matter how, or in what
order, they exchange entries.

What the log does *not* do is as deliberate as what it does:

- **No global order.** Entries from different writers have no order relative
  to each other. Applications that need one build it on top; the log does not
  pretend to know it.
- **No consensus.** Concurrent writers do not coordinate; they use different
  writer IDs. A replica never has to ask anyone's permission to append.
- **No silent conflict resolution.** If two replicas each hold a *different*
  entry at the same `(writer_id, writer_seq)` coordinate, the writer's history
  has forked — a duplicated process, a restored backup, a cloned disk. The log
  reports `writer_fork` and stops. It never picks a winner, because either
  choice would discard someone's data while looking like success.

Replicas synchronize by exchanging **frontiers** — for each writer, the
sequence number and entry ID at the tip — and then fetching exactly the ranges
the other side is missing. Entries are immutable JSON objects with a
canonical byte encoding (RFC 8785 / JCS), so every runtime agrees on the exact
bytes of every entry.

This repository contains the protocol, a reference implementation in Elixir,
and an independent implementation in TypeScript for Cloudflare Durable
Objects, with a shared conformance corpus that both are checked against
byte-for-byte.

## An entry, and a merge

Every entry has exactly eight fields:

```json
{
  "version": 1,
  "log_id":        "7d4b…",
  "entry_id":      "c1a9…",
  "writer_id":     "a3f2…",
  "writer_seq":    4,
  "prev_entry_id": "9e77…",
  "created_at":    "2026-08-24T16:02:11.318Z",
  "body":          { "op": "set-title", "title": "Draft 3" }
}
```

`writer_seq` starts at 1 and `prev_entry_id` names the previous entry in the
same writer's sequence, so a sequence is also a hash-free chain. The `body`
is application data; the log stores it and never interprets it.

Two replicas holding

```text
A = { alice -> [a1 a2 a3],   bob -> [b1] }
B = { alice -> [a1 a2],      bob -> [b1 b2 b3] }
```

merge to `{ alice -> [a1 a2 a3], bob -> [b1 b2 b3] }`. If `B` instead held
`alice -> [a1 a2 x3]` where `x3 ≠ a3`, the merge is refused with
`{:error, {:writer_fork, %{writer_id: alice, seq: 3}}}` and neither replica
is changed.

## Using the Elixir library

The library lives in `commonplace_log/` and stores each log in its own SQLite
database. The single-writer rule is enforced locally: a per-log server process
holds an exclusive lock and a durable writer identity, so an ordinary restart
keeps its identity and a cloned or restored database is required to take a new
one.

```elixir
alias Commonplace.Log.DocumentProfile

log_id = Commonplace.Log.UUID.uuidv7()
{:ok, doc} = DocumentProfile.create_log(log_id, [])

{:ok, %{writer_seq: 1, entry_id: _}} =
  DocumentProfile.append(doc, %{"op" => "set-title", "title" => "Draft 3"}, [])
```

`DocumentProfile` is the surface for the common case of a document with one
appending process. It also offers an **exact-retry** path:
`prepare_append/3` derives entry IDs deterministically from an
`:operation_id`, a caller-supplied `:created_at`, and the log's current state,
so a process that crashes between preparing and learning whether its commit
landed can re-prepare, get byte-identical entries, and commit again without
risk of a duplicate or a fork.

Below that façade, `Commonplace.LogStore.SQLite` implements the multi-writer
`Commonplace.LogStore` behaviour (`create_log`, `append`, `merge`, `frontier`,
`read_writer`, `tail_local`), and `Commonplace.Log.Sync` drives frontier and
range synchronization between two stores. Errors from every layer have the
shape `{:error, {code, details}}`, where protocol codes (`writer_gap`,
`writer_fork`, `invalid_entry`, `log_not_found`, …) are distinct from
`:storage` failures, so a caller can tell a statement about the log's contents
from an I/O problem.

Configure the storage directory with:

```elixir
config :commonplace_log, Commonplace.LogStore.SQLite,
  data_dir: "/var/lib/commonplace-log"
```

It defaults to `commonplace_log_data/` under the current directory.

## Two implementations, one corpus

The Elixir library is **normative**: where the prose specification and the
Elixir behaviour disagree, the Elixir behaviour wins and the specification is
amended (see [Amendment 1](docs/protocol/0.1-amendment-1-beam-native.md)).

The TypeScript code in `worker/` is an **independent, conforming workalike**
for Cloudflare Durable Objects. It shares no code with the Elixir library —
each has its own validator, canonicalizer, and merge classifier, written
against the same specification. Both are checked
against the same language-neutral vectors in `conformance/`: canonical-JSON
cases with expected bytes, and invalid-entry cases that fix an error code and
a reason slug both runtimes must produce. `conformance/check.sh` compares the
two runtimes with each other and with the stored expectations; `fuzz.sh` does
seeded differential fuzzing between them.

The point of a second implementation is that the protocol cannot then be
accidentally defined by Elixir internals — any behaviour only one runtime
exhibits is a bug in one of them or a gap in the specification.

The worker also contains a realm node: one Durable Object per realm that
holds the realm's SQLite and manages a Cloudflare Container running the Elixir
engine. Realm ids are opaque lowercase canonical UUIDs, ruled 2026-08-25 (1a).
The engine reaches its storage only through `http://storage.internal`,
which a Worker-side outbound handler resolves from the platform-supplied
container identity — nothing the engine sends can select another realm's
storage. This is deployed on a development account and has been exercised end
to end: appends from the BEAM inside the container, read back through the
sidecar path of the same object; a container restart producing a new
incarnation while the log survives; and a stale lease epoch refused at commit
with nothing written. What it has not yet met, and what remains unverified, is
recorded in [`docs/sp4b-deployment-readiness.md`](docs/sp4b-deployment-readiness.md).

## Repository layout

| Path | What is here |
| --- | --- |
| [`docs/commonplace-monotonic-log-spec.md`](docs/commonplace-monotonic-log-spec.md) | The protocol, version 0.1-draft. Kept byte-identical to what its author wrote; changes are recorded as amendments in `docs/protocol/`. |
| [`docs/proposals/`](docs/proposals/) | The architecture proposal that made Elixir normative and set the Cloudflare deployment direction. |
| [`docs/superpowers/plans/`](docs/superpowers/plans/) | The implementation plans and decision ledgers the code was built from, including decisions that were considered and rejected. They are kept in the open on purpose: the reasoning is part of the record. |
| `commonplace_log/` | The Elixir library. `Entry` and `Jcs` validate entries and produce canonical bytes; `MergePlan` classifies a merge without side effects; `Engine` makes the domain decisions; `Persistence` is the storage boundary, with `LocalSQLite` and `CloudflareSidecar` adapters; `LogStore.SQLite` is the per-log store; `DocumentProfile` is the single-lane document surface; `Sync` synchronizes two stores. |
| `worker/` | The TypeScript workalike. `src/do/` is the per-log Durable Object (frozen as a milestone); `src/realm/` is the multi-log sidecar for a BEAM container. A test walks the import graph to ensure `realm/` never borrows `do/`'s canonicalization or merge code. |
| `conformance/` | The shared vectors and the scripts that run them. One canonical-JSON case is deliberately wrong so the harness has to observe its own expected failure before it may report green. |

## Running the checks

Tool versions are pinned in `.tool-versions` (Erlang 27.3, Elixir 1.18, Node 24)
and CI runs exactly the commands below.

```sh
cd commonplace_log && mix deps.get && mix test      # Elixir, incl. property tests (~80 s)
cd ../worker && npm ci && npm test                  # TypeScript, against real DO SQLite
cd .. && bash conformance/check.sh                  # cross-runtime byte equality
bash conformance/fuzz.sh                            # seeded differential fuzzing
```

Some tests exist to be watched *failing*: the persistence-contract suite runs
deliberately broken adapters under `PERSISTENCE_CONTRACT_MUTATION` to prove it
can go red, because a cross-adapter suite that cannot fail proves nothing.

## Things that look like oversights and are not

Each of these was a decision. Changing one without reading its reason would
remove a guarantee.

- **The lease epoch is verified inside the commit transaction, never checked
  beforehand.** An earlier version compared the epoch and then merged; the
  race between those two reads was observed writing a displaced writer's row
  under the newly current epoch. A check the commit does not consult is not
  a fence. See the `DocumentProfile` moduledoc.
- **Entry identity for prepared appends is derived, not minted.** A generated
  UUID only survives an in-process retry; a caller that crashes and
  re-prepares would mint a fresh ID and fork its own log. This is also why
  `created_at` must be caller-supplied on that path.
- **`Engine.append` still mints its own entry ID.** It is the base-protocol
  path; the exact-retry guarantee lives on the `DocumentProfile` surface.
- **A displaced appender gets `writer_lease_fenced`, not `writer_fork`.** An
  obsolete authority is not a competing account of history, and reporting
  corruption for a routine failover would train operators to ignore the
  alarm.
- **`conformance/` is a cross-repository surface.** Adding vectors is safe;
  changing byte rules, numbering, or `expected.hex` files must be announced
  to the sibling projects that consume them.

## Not in version 0.1

Merkle trees or content-addressed entry IDs; a CRDT interpretation; a total
order across writers; consensus or leader election; deletion or compaction
(an application deletes by appending a tombstone); capabilities or
signatures; cross-log transactions.

## Status

The library, the workalike, and the Cloudflare realm deployment are complete
and green. The repository is waiting on a naming and placement policy
decision for realms, and on the needs of the sibling libraries (`commonplace-doc`, `commonplace-doc-sync`, `commonplace-log-reducer`)
that build on this one.

## License

MIT — see [LICENSE](LICENSE).
