# Commonplace Monotonic Log

`commonplace-log` implements an append-only log made from independent, gapless writer sequences. Each writer owns a sequence numbered from 1; a log is the union of those sequences. Replicas converge by retaining the longer compatible prefix for each writer.

There is no global order between writers, consensus, or CRDT conflict resolution. Concurrent writes are valid when they use different writer IDs. If two live replicas append with the same writer ID, they create a fork: the system reports and refuses it and never silently chooses a branch.

## Authority and protocol

The normative protocol is [the Commonplace Monotonic Log specification](docs/commonplace-monotonic-log-spec.md), version 0.1-draft, as amended by [Amendment 1: BEAM-Native Recentering](docs/protocol/0.1-amendment-1-beam-native.md). The amendment makes the Elixir implementation under `commonplace_log/` normative. The reasoning and deployment direction are recorded in [the BEAM-native architecture proposal](docs/proposals/2026-08-22-beam-native-revision.md).

The Elixir library is the reference implementation for entry validity, canonical JSON, merge classification, and synchronization. The TypeScript Cloudflare Durable Object is a complete, conforming workalike: it implements the protocol independently and is checked against the same language-neutral vectors. That independence helps ensure the protocol is not accidentally defined by Elixir internals.

## Repository layout

| Path | What is here |
| --- | --- |
| `conformance/` | Shared RFC 8785 canonical-JSON and invalid-entry vectors. Each invalid case fixes an error code and shared reason slug. `check.sh` compares both runtimes byte-for-byte with each other and with stored expectations; `fuzz.sh` runs seeded differential fuzzing. The `999-*` canonical-JSON vector is deliberately wrong so the harness must observe its expected failure before reporting success. |
| `commonplace_log/` | The normative Elixir library. `Entry` and `JCS` validate entries and produce canonical JSON; `MergePlan` classifies merges without side effects; `Engine` owns domain decisions; `Persistence` defines the storage boundary and `Persistence.LocalSQLite` implements it. The per-log SQLite server holds the cross-process lock and writer identity, `Commonplace.LogStore` is the public surface, and `Sync` performs frontier/range synchronization. Storage adapters move rows according to engine decisions; they do not reimplement domain classification. |
| `worker/` | An independent TypeScript workalike for Cloudflare Durable Objects: entry validation and canonical JSON, SQLite schema, merge classification, store operations, and versioned HTTP endpoints. Its tests exercise the specification's conformance requirements against real Durable Object SQLite storage. |
| `docs/` | The protocol specification and amendment, architecture proposal, and implementation plans and decision ledgers under `docs/superpowers/plans/`. |

## Run the checks

Prerequisites and tool versions are recorded in `.tool-versions`; dependencies are managed separately in the Elixir and Node projects.

```sh
# Elixir library, including property tests
cd commonplace_log
mix test

# TypeScript Durable Object
cd ../worker
npm test

# From the repository root: stored vectors and cross-runtime byte equality
cd ..
bash conformance/check.sh

# Seeded cross-runtime differential fuzzing
bash conformance/fuzz.sh
```

The Elixir suite includes property tests (200 generated cases each) and so takes appreciably longer than a plain unit suite — roughly 70 seconds, against a couple of seconds for the rest. Measured on 2026-08-22:

| Check | Result |
| --- | --- |
| `mix test` (Elixir) | 1 doctest, 5 properties, 165 tests, 0 failures — ~68 s |
| `npm test` (TypeScript) | 218 tests across 11 files, 0 failures |
| `conformance/check.sh` | GREEN over 19 canonical-JSON cases |
| Shared corpus | 19 canonical-JSON vectors, 30 invalid-entry vectors |

Re-run the commands above rather than trusting these figures; they are a snapshot, not a guarantee.

## Planned work

The next phase is the Cloudflare realm deployment described in the architecture proposal: a named Cloudflare Container runs the BEAM engine, while its managing Durable Object is a durable SQLite sidecar holding many logs for that realm. The BEAM side reaches storage through a read-set/commit-plan persistence adapter, keeping protocol decisions in the engine rather than in the sidecar.

After that comes integration with the wider Commonplace system. Per-log Durable Objects remain a supported sharding strategy, but are not the default deployment unit.

## Deliberate 0.1 limits

Version 0.1 does not include:

- Merkle trees or content-addressed entry IDs
- a CRDT interpretation
- a total order across writers
- consensus or leader election
- deletion or compaction; application-level deletion is represented by an appended tombstone entry
- capabilities or signatures
- cross-log transactions
