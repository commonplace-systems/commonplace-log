# Restore HTTP native results

The retained native evidence covers one real loopback HTTP workflow through Elixir `Httpc`, local Wrangler, the fixed test-only Durable Object wrapper, and SQLite persistence. The accepted run completed the nine requests, including malformed reachability, provisioning, partial restore, pending ordinary-operation fence, a next batch completing the pending restore in the same Wrangler process, exact two-log readback, and idempotent replay. This nine-request HTTP workflow does not test a process restart; the separate local DO suite covers restart behavior. The fixture makes no cloud, authentication, provisioning, or application-activation claim.

## Runs

| Run | Session | Source HEAD | Native / verdict | Result | Runtime files | Groups |
|---|---:|---|---:|---|---:|---|
| `restore-http-native-1` | 23514 | `ac6bd5cd06092bce568fe214fbc0ba3a0933834f` | `127 / 125` | root launch PATH omitted Erlang bin; exec erl not found | 3220 | elixirc absent=True rc=127 kill=False |
| `restore-http-native-2` | 37219 | `ac6bd5cd06092bce568fe214fbc0ba3a0933834f` | `1 / 125` | ordinary create_log empty metadata calls to_existing_atom format_version before HTTP in minimal VM | 3220 | elixirc absent=True rc=0 kill=False, wrangler absent=True rc=143 kill=False, elixir-test absent=True rc=1 kill=False |
| `restore-http-native-3` | 49834 | `0382c83b7b0d1fbe5e7e5bbcfc4afd1bf961223f` | `1 / 125` | fixture expected constraint_violation; actual pending bundle fence returns obsolete_epoch per store.ts | 3221 | elixirc absent=True rc=0 kill=False, wrangler absent=True rc=143 kill=False, elixir-test absent=True rc=1 kill=False |
| `restore-http-native-4` | 58475 | `5cc32895a118d04398ac22175077cccbefdfa32b` | `0 / 0` | accepted | 3221 | elixirc absent=True rc=0 kill=False, wrangler absent=True rc=143 kill=False, elixir-test absent=True rc=0 kill=False |

Run 1 retained the launcher PATH failure (`erl` unavailable before Wrangler); run 2 retained the empty-metadata `to_existing_atom` fixture failure; run 3 retained the stale `constraint_violation` expectation while the observed result was `obsolete_epoch`. Those failures remain represented as failures and were not relabeled. Run 4 is the accepted fresh full workflow: compile `0`, test `0`, one test defined/executed with zero failures/skips, and wrapper verdict `0`. Wrangler exit `143` is the recorded normal TERM cleanup; every known group was absent and no run used KILL.

## Exact retained commands and source pins

Each run retains the exact compile, Wrangler, and test argument arrays in its `command.json`; the report JSON embeds those objects and records the raw file hashes. The following is the shell template for the four fresh output paths; the exact per-run argv is retained in each `command.json`:

```bash
cd /home/jes/commonplace-log-restore-http
python3 docs/measurements/restore-http-native-1/run_restore_http.py \
  /home/jes/commonplace-log-restore-http/tmp/restore-http-native-N
```

The runs use the cached BEAM root `/home/jes/codex-save-state-1/tmp/origin-receipt-1/_build/test/lib`, local dependency tree `/home/jes/commonplace-log/worker/node_modules`, client source `4fa621db5d257260118fbf649049402ff09b5ef6`, wire product `6194033`, fixture base `5245b1b`, and the actual runner HEAD recorded per run.

## Hash and cleanup evidence

Every run retains `input-sha256.json`, `post-sha256.json`, `input-equality.json`, `native.rc`, `process-groups.json`, `command.json`, `source-pins.json`, root completion, and captured stdout/stderr. Pre/post hashes compare equal for each run’s captured PRE file list; because the runner enumerates runtime files once before hashing, this does not prove that no file appeared after PRE. The input sets contain 10 Elixir files, 23 worker source/config files, 847 cached BEAM files, and 3,220 or 3,221 worker runtime files.

The runtime count changed from 3,220 in runs 1–2 to 3,221 in runs 3–4. Set difference found exactly one added file between runs 2 and 3:

`/home/jes/commonplace-log/worker/node_modules/.mf/cf.json`

It was present with the same hash in runs 3 and 4. This is a cross-run inventory difference only; it does not attribute the file’s creation to a particular point during run 2, and no raw output was edited or replayed. The exact hash for every retained raw output file is in [`RESULTS.json`](./RESULTS.json).

## Limits

- Bounds: compile 120 seconds, Wrangler startup 30 seconds, test 180 seconds, TERM grace 5 seconds, KILL grace 2 seconds.
- Runs 1–2 retain the original runner environment; run 1 records the missing Erlang PATH failure. Runs 3–4 use private HOME/XDG/TMPDIR, `ERL_FLAGS=+S 2:2`, and `/home/jes/.asdf/installs/erlang/27.3.4.8/bin` prepended to PATH.
- Scope: local synthetic fixed-target Durable Object wrapper and SQLite persistence reached over real loopback HTTP.
- Excluded claims: real cloud Durable Object RPC, provider authentication, cloud deployment, target provisioning, application activation, and public grants.

The raw artifact SHA-256 maps, retained root completion records, exact command objects, native return records, and process-group records are all bound in `RESULTS.json`.
