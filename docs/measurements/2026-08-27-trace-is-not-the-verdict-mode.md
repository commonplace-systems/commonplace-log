# `mix test --trace` cannot fail this suite the way `mix test` can

**Measured 2026-08-27 at 32c39cc. Numbers re-derived from the run logs, not from recollection.**

## The finding

`--trace` changes what a run is *able* to observe, in two ways, and both are documented:

- `ex_unit/lib/ex_unit/runner.ex:564` — `defp get_timeout(config, tags) do if config.trace do :infinity else …`.
  Unconditional: **an explicit `--timeout` cannot override it**, because the tag branch is never reached.
- `mix/tasks/test.ex:204` — "`--trace` … Automatically sets `--max-cases` to `1`." So a traced run
  is also **serial**, and cannot reproduce anything that depends on concurrency.

⇒ **A traced run is a diagnostic mode, not a verdict mode.** It prints more and observes less.

## The evidence from this suite

Two runs of the same tree, the same afternoon, under comparable host load:

| run | wall clock | async | sync | result |
|---|---|---|---|---|
| `mix test --trace` | 453.6 s | 41.5 s | 412.0 s | 315 tests, **0 failures** |
| `mix test` | 264.4 s | 40.0 s | 224.3 s | 315 tests, **1 failure** |

The traced run was **1.7× slower** with its async portion unchanged (41.5 vs 40.0) while the sync
portion nearly doubled — the signature of `--max-cases 1`. ⇒ The doc line is corroborated by an
independent physical consequence, not only by re-reading the documentation.

The failure only the plain run could produce:

```
1) property stale-retry safety (Commonplace.Log.MergeLawsTest)
   test/merge_laws_test.exs:153
   ** (ExUnit.TimeoutError) property timed out after 60000ms
```

Box line for that run: started 17:51:06Z, load1 17.22, available 4268 MB, **9 concurrent `mix test`
processes**; finished 17:55:45Z, rc 2. Sibling properties in the same suite were measured at
54,034 ms and 129,374 ms in that window against a ~2 s baseline.

## What this costs you if you forget it

I used `--trace` to investigate that flaky failure — the natural choice, because it names each test
— and thereby selected the one mode that could not reproduce it. I then reported "the failures did
not reproduce" from a run that was **structurally incapable of reproducing them on both axes**.

⇒ **THE DIAGNOSTIC MODE AND THE GATING MODE ARE NOT THE SAME MODE, AND THE ONE THAT PRINTS MORE IS
THE ONE THAT OBSERVES LESS.**

## Rules for this repo

1. **The verdict comes from plain `mix test`.** CI does this (`.github/workflows/ci.yml`, check 2 of
   6); do not "improve" it to `--trace` for nicer output.
2. Use `--trace` to get arm *names*, and treat its green as silent about timeouts and concurrency.
3. **If the plain run fails and the traced run passes, that disagreement is the finding** — report
   it as a timing-or-concurrency class, not as a flake to be retried away. The two runs answer
   different questions, so a divergence between them is information rather than noise.
4. A timeout under host contention is not automatically a defect and not automatically noise.
   Record which side of the load window it came from; see `2026-08-26-wal-growth.md` for the
   instrument-discipline half.

## Still open at the time of writing

`property stale-retry safety` has fired once, under a load-44 host with 9 concurrent suites, and has
**never been observed at rest**. It is not closed by this document: a class that would explain a red
is exactly when a red gets retired by association.
