# 2026-08-27 — `property stale-retry safety` times out, and the run that proved it was already running

Two findings, one of which cost more than the measurement.

## The question, and why it was pre-registered

`property stale-retry safety` (`commonplace_log/test/merge_laws_test.exs:153`) had been
seen to hit ExUnit's whole-test 60,000 ms ceiling **once, under load**, and never at rest.
The question: **does it time out at rest, or only under contention?**

The interpretation was fixed *before* the run, in a verdict table with rows A–F, for the
reason a threshold argued at firing time is the one that loses: by then the run is what
you want and the number is what stands between you and it.

## The run

```
2026-08-27 19:13:29Z   mix test, seed 329237, backgrounded (setsid)
rc=2      Finished in 250.4 seconds
1 doctest, 5 properties, 315 tests, 2 failures, 2 skipped
  1) property stale-retry safety   merge_laws_test.exs:153   TimeoutError 60000ms
  2) property associativity        merge_laws_test.exs:98    TimeoutError 60000ms
box: 194 samples covering the whole window
     available MIN 3537 MB · pessimistic headroom MIN 976 MB · load1 MAX 19.89 · suites MAX 2
```

**Verdict D** on `stale-retry safety` (rc≠0, same arm timed out, sampled minimum headroom
below the floor) — *host-suspect: not a finding and not a closure*. **Verdict E** on
`associativity`, which had never been seen to time out before and is recorded separately
rather than folded in as corroboration.

## ⛔ Why verdict D is worth almost nothing here — the two floors

The table's floor was **breached at sample 2, one second in, and in 193 of 194 samples.**
D did not survive a test; it was arithmetic:

```
the GATE tests:   available - SUITE_COST(500) > 1500     4093-500 = 3593   passes easily
the TABLE tests:  pessimistic_headroom       > 1500      1541              at the line
                  headroom = available - (serve_hwm - serve_rss) = 4093 - (2854-302)
```

One word, **"floor"**, for two quantities ~2552 MB apart — the memory the standing
`commonplace serve` *could* reclaim is subtracted in one and not the other. So the
pre-flight will happily start a run that the verdict table scores as a floor breach, and
rows B and D become selected by arithmetic rather than by the box.

**A re-run under this table returns D again.** The remedy D prescribes is inoperative as
written. The table is not revised here — it was fixed at 18:37Z and rescuing a result by
editing the rule afterwards is the failure the pre-registration exists to prevent. **The
question remains open**, and the honest output of this run is that the instrument could
not discriminate.

*A floor your arithmetic guarantees you breach cannot exonerate anything.* (The same
object as: a baseline you inferred from a config file cannot go down.)

## ⚠️ Post hoc, and labelled as such

Not in rows A–F. Noticed only after seeing the result, so it is a hypothesis for a better
instrument and **not** an answer:

- **Both** stacktraces terminate in SQLite open/configure, not in merge logic —
  `LocalSQLite.configure/1` (`local_sqlite.ex:217`) and `LocalSQLite.create_log/3`
  (`local_sqlite.ex:57`), both via `open_replica!/2`, both `@cases 200`.
- An earlier run of the same suite at 18:47Z: **154.1 s, 0 failures**, headroom min 1410.
  This one: **250.4 s, 2 timeouts**, headroom min 976. +62% wall clock.
- 33 contiguous samples (19:13:52–19:15:36Z) saw `suites=2`. The window was **not
  exclusive**. The instrument counts mix-test BEAMs globally and cannot attribute them.

⇒ This points at I/O contention on SQLite open rather than a slow property. It is not
established.

## ✅ What the next attempt needs — not another `mix test`

A whole-suite pass/fail plus a whole-box memory line **cannot** separate *"this property is
marginal against 60 s"* from *"opening a SQLite replica is slow while anything else is doing
I/O."* The question needs a per-test instrument: time `LocalSQLite.open`/`configure`
directly, or run the two properties alone with the seed pinned.

Three runs have now been spent on an apparatus that cannot answer the question it was
built for. **A check whose result does not change what happens next is decoration** — and
this one had six rows, two of which were unreachable.

## ⛔⛔ The finding that cost more than the measurement: the green arm *is* the action

At **18:47:22Z** the pre-flight gate above was demonstrated with two arms:

```
RED   arm: floor forced to 999999  → "PRE-FLIGHT REFUSES …"   rc 75   correct
GREEN arm: the REAL floor, to show the gate does NOT refuse on correct state
           → it did not refuse → so it PROCEEDED → and proceeding is `mix test`
```

An outer `timeout 20` killed the wrapper and printed `Terminated`; `mix test` was
reparented and **ran to completion, 18:47:28–18:50:02Z, 154 seconds, unslotted.** The
result was logged as *"(no floor refusal — correct)"* and "nothing running" was reported
twice afterwards. The artifact was on disk 2m20s later and was not opened until a later
session reconciled unaccounted scratchpad files against the transcript.

> ⭐ **For a gate that guards an action, the red arm is cheap and the GREEN ARM IS THE
> ACTION.** The only way to observe *not refusing* is to let the guarded thing happen. So
> "demonstrate that a gate stays green on known-good input" — a sound rule everywhere else
> — instructs you, for a start-gate, to perform the very act the gate exists to prevent.
> **The proof that the gate is safe is an unslotted run.**

**The fix is to stub the ACTION, not the threshold.** Threshold-stubbing still ends in the
action. `commonplace_log`'s runner now takes `QUIET_RUN_STUB_ACTION=1`, which replaces
`timeout 1200 mix test` with `true` and stamps the mode into the artifact, so a green arm
proves the pre-flight passed *on the real path* without proving it by executing. Both arms
were re-fired under the stub (red 75, green 0, `quiet.log` = 137 bytes of stub message,
zero mix-test BEAMs), and the gate was then verified **still armed** — exercised and armed
are separate observations.

Two limits, both real:

- **Some refusals cannot be stubbed at all.** A guard that reads the *result* of the action
  is downstream of it by construction. Those should be labelled untestable-in-principle,
  not demonstrated once by performing them.
- **A `--preflight-only` flag is weaker than a stub**: it proves the gate passes and stops;
  it does not prove that a run which passes then proceeds correctly.

And the reading defect underneath it: `Terminated` plus no process was taken as the
verdict. **A killed run, a finished run, and a run that never started all leave no
process.** The artifact is the verdict, not the process's absence.

## Related

- `docs/measurements/2026-08-27-trace-is-not-the-verdict-mode.md` — why `--trace` cannot be
  used to chase these timeouts: it sets the timeout to `:infinity` unconditionally *and*
  forces `--max-cases 1`, so it is structurally blind to both the ceiling and the
  concurrency. It had no readers until this line; it is the first thing someone reaching
  for `--trace` on the timeouts above needs.
- `docs/measurements/2026-08-26-wal-growth.md` — the WAL plateaus at ~4.14 MB rather than
  growing, so it is not a candidate explanation for the I/O above.

## Status of this document

⚠️ **This tree is not gated.** The last full suite run against it is the one recorded
above, `3cb0d78` plus this commit's prose and comment-only test pointers. No suite has run
against those. Declared rather than repaired: re-running a 250 s suite to bless comments
would consume a shared box to change nothing.
