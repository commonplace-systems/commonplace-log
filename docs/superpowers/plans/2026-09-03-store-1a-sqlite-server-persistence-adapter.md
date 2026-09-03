# STORE-1a — one meaning for `handle.adapter`

**Round dispatched by `commonplace-plan` (QUEUE row 609) to `commonplace-cell`, 2026-09-03. Base `main 7f8e3b4`.**
Follows `STORE-0` (measurement) and the `STORE-1` STOP that found this defect before a branch existed.

## 1. The defect

`Commonplace.Log.DocumentProfile.Handle` carries one `:adapter` field (`document_profile.ex:87-88`), filled from the
lane's activation (`:237-238`). **The two lanes put modules of two different behaviours in it:**

| lane | `adapter:` | behaviour | `frontier` | `tail_local` | `read_set` |
|---|---|---|---|---|---|
| `Lane.Sidecar` | `Persistence.CloudflareSidecar` | **`Persistence`** | `/2` | `/3` | `/3` |
| `Lane.SQLite` (before) | `LogStore.SQLite` | **`LogStore`** | **`/1`** | **`/2`** | **absent** |

`Frontier.frontier_value/1` and `Frontier.read_through/3` are already adapter-generic — they take a bound log
`%{module:, store:, log_id:}` and call `module.frontier(store, log_id)` at **arity 2** (`frontier.ex:96`, `:114`).
So the generic read path was callable from a sidecar handle and raised `UndefinedFunctionError` from a SQLite one.

⇒ **That is why `commonplace-doc`'s `DocHost.LogAdapter.CommonplaceLog` reads `Commonplace.LogStore.SQLite`
directly at five sites** — the monotonic-log spec §14 coupling `STORE-1b` removes. It could not be removed from the
doc side alone, because there was no `Persistence` module to point a handle at.

**The generic path was not missing, it was private.** `log_store/sqlite/server.ex:220` already builds
`%{module: LocalSQLite, store: state.store, log_id: state.log_id}` and serves `:frontier_value` and `:read_through`
with it. The server holds it; the lane did not publish it.

## 2. The change

- **New** `Commonplace.Log.Persistence.SQLiteServer` — a `Persistence` adapter whose store handle is the **server**,
  delegating all seven callbacks to `Commonplace.LogStore.SQLite.Server` calls.
- **`Lane.SQLite.activate/2`** returns `adapter: SQLiteServer`, so `handle.adapter` is uniformly a `Persistence`
  module on both lanes.
- **Three new `Server` calls**: `read_set/2`, `commit/2`, and `log_id/1`. The dispatch named one (`read_set`);
  the other two are justified in §4.

⛔ **The `Persistence`, `Lane` and `LogStore` behaviours are unchanged.** No `worker/` change. No doc, next, or pin bump.
⛔ **`state.store` is never published.** It is an open connection the GenServer serializes access to, beside a
`lock_conn` and the writer identity; publishing it would let a caller bypass both. Every call routes through the server.

## 3. Arms

- [x] **L1 RED AT BASE** — `Frontier.frontier_value/1` and `Frontier.read_through/3` over a SQLite-lane handle's own
      `adapter`/`store`. At base: `UndefinedFunctionError`, `frontier/2` undefined. After: equals the server's own
      `frontier_value`/`read_through` answers.
      `test "a SQLite-lane handle reaches the generic frontier value through handle.adapter"`
      `test "a SQLite-lane handle reads its own prefix through the generic read_through"`
- [x] **L2 CONTROL** — the same generic call over a **sidecar**-lane handle (loopback transport) passes at base AND head.
      A failure here means the generic helpers broke, not this adapter.
      `test "a sidecar-lane handle reaches the same generic frontier value"`
- [x] **L3** — `read_set/3` through the proxy equals `Server.read_set/2` for the same tips; an unknown tip is refused
      identically by both (`%Frontier.Error{reason: :unknown_tip}`), not answered with a truncated prefix.
      `test "read_set through the proxy answers the server's own state, and refuses an unknown tip"`
- [x] **L4** — `tail_local/3` and `read_writer/4` through the proxy equal the server's direct answers; counts named (2 and 2).
      `test "tail_local and read_writer through the proxy equal the server's direct answers"`
- [x] **Log-binding guard, both polarities** — six callbacks refuse a `log_id` the server does not own with
      `{:error, :log_mismatch}`, and the owned `log_id` is **not** refused (the control that stops the arm passing
      because everything refuses).
      `test "every read refuses a log_id the server does not own"`
- [x] **L7** — the `Inspect` impl (`document_profile.ex:107`), the field's only other consumer, still renders and now
      prints `adapter: Commonplace.Log.Persistence.SQLiteServer`.
      `test "the handle Inspect impl still renders, naming the new adapter"`
- [x] **L5/L6 controls** — `test/sqlite_server_test.exs` and unrelated adapter suites unchanged: file counts named at
      base and head in the round receipt, not asserted here.

## 4. Recorded decisions

**Why `log_id/1` and a guard on every callback.** A server owns one log for its lifetime, and `LocalSQLite` answers
about *that* log whatever `log_id` the caller passes. Without a check, a mismatched argument would be **answered**
rather than refused — another log's data with no error. `LocalSQLite` itself guards this way and returns
`{:error, :log_mismatch}`; the proxy returns the same term. Cost is one extra `GenServer.call` per operation, beside
work that already does SQLite I/O.

**Why `commit/2` is proxied rather than stubbed.** A `Persistence` adapter that refuses `commit` is a landmine: it
compiles, and fails far away at runtime. Routing it through the server preserves the process serialization, and the
`CommitPlan` carries its own expected revision and epoch which `LocalSQLite.commit/2` still checks — the CAS is not
weakened. It is also what lets `Engine.merge/4` seed a log through this adapter.

**Two contract shapes this adapter cannot present, by construction rather than omission.**

1. `{:error, :not_found}` for reads of an uncreated log. `Server.init/1` creates or opens the log before the process
   exists, so "store open, log absent" is unreachable through a server handle. ⇒ **This adapter is deliberately NOT
   wired into `test/support/persistence_contract.ex`**, whose arm *"all reads of an unknown log return not_found and
   create no logical state"* asserts exactly that state. Wiring it in would make the shared contract red for a
   reason that is not a defect. Recorded here rather than worked around.
2. `create_log/3` ignores its `metadata`. `Server.create_log/1` commits `%{format_version: 1}`, matching how the
   server creates the log at init.

## 5. What this round does not do

`STORE-1b` (commonplace-doc) bumps the log pin and rebinds the DocHost adapter's five read sites. The `arrival_seq`
semantic change named in `STORE-0` — per-replica under SQLite, per-log and store-assigned under the Durable Object —
is **not** addressed here and remains a named fact for that round.
