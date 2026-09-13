# Workers-pool focused measurement — run 1

This retained run selected 43 assertions from the deployed-base provider fixture. It is a failed run and is preserved for diagnosis; no rerun or result promotion is implied.

- Source: `474cf369c175dc7f9685cbb22f901d25278879ce`
- Fixture: `cc8afaac0f84fde21a621e37300cf0cb755d47ca`
- Native child exit: `1`; runner verdict exit: `125`
- Assertion records: **20 passed, 1 failed, 22 pending**

The first failure was **deployed-base allocation and registry does not restore a revoked read hash on an allocation retry**. The materialized run raised `ReferenceError: refused is not defined` at `tmp/workers-pool-1/context/worker/src/realm/realm_auth.ts:298`, reached from the fixture at line 236. Source commit `4a22c1d` later added that helper; this retained run predates it and does not validate the correction.

The Vitest aggregate reports 43 total, 20 passed, 1 failed, and `numPendingTests: 0`, while its assertion records contain 22 pending entries after `--bail=1`. The assertion records and retained runner verdict are used for selected-case status; the aggregate discrepancy is recorded rather than normalized away.

`stderr` contains one unattributed workerd request-stream diagnostic (`Can't read from request stream after response has been sent`) alongside warnings. It has no URL, test name, or selected-assertion association, so this evidence does not identify a product or fixture cause.

Input integrity and cleanup checks passed: the retained input count is 3265 and pre/post equal; the runtime inventory stayed at 3221 with no additions or removals; process group `2071378` was absent after cleanup, with no TERM, KILL, timeout, or first-signal event.

The unchanged raw output is under `tmp/workers-pool-1/`. `OUTPUT-MANIFEST-1.json` hashes every retained regular file there without following symlinks; the runtime `context/worker/node_modules` symlink is recorded as excluded rather than traversed.
