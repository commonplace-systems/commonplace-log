# REALM-REMOVE-1b verification

Measured 2026-09-05 in `/home/jes/codex-realm-arms`, a clean prepared clone at
`9ff2646517543ae6fb39ef1063ae2beb6bb90ead`. Implementation base:
`79edae4a565976e3c9a363902165548b72dc584d`. Node `v24.13.1`, npm `11.8.0`,
Vitest `3.2.7`. Dispatch: boss-clod, clod-squad message 29787; follow-up
adjudication: commonplace-plan message 29790.

## Result

The preserved implementation passed D1–D3 and R1–R6: **308 tests in 22 files**.
The unchanged R4 test failed when the inert `not_found` return was deliberately
removed, and passed again after byte-for-byte restoration. The failure was the
registry-row retention assertion, not a setup or compilation failure.

Typechecking is **mixed**: the base already has two TS2307 errors, while the
preserved branch adds two TS2532 errors in the dispatcher-supplied delete-all
test. The narrow repair accompanying this report adds row-count assertions and
explicit undefined guards. It removes both additional errors without changing
application code. The two inherited TS2307 errors remain; typecheck is **not green**.
The final repaired tree also passed **308 tests in 22 files**, rc 0; its two
remaining diagnostic lines were verified byte-identical to the base's.

This report is verification evidence, not a merge warrant or deployment result.
Neither the original guarded worktree nor the parked launch checkout was edited.

## Reproduction and artifacts

Raw output, bare process exit statuses, mutation diffs, and a checksum manifest
are in [the evidence directory](2026-09-05-realm-remove-1b-arms/).
Commands were redirected directly to files; `$?` was captured immediately after
the command, before any display command. No verdict was taken from a pipeline.
Mutation subprocess statuses were captured directly with Python `subprocess.run`.

From the candidate's `worker/`:

```sh
npm ci
npx vitest run test/realm/delete_all.workers.test.ts test/realm/realm_remove.workers.test.ts --reporter=verbose
npx vitest run
npm run typecheck
npx vitest run test/realm/realm_remove.workers.test.ts -t 'R4: registry failure' --reporter=verbose
```

The R4 command was run once with the recorded mutation and once after restoration.
The final repaired tree was checked with `npm run typecheck` and
`npx vitest run --reporter=verbose`.

The base's worker source was extracted with `git archive` at the full base SHA
into `/home/jes/codex-realm-arms-evidence/base/worker`. Its `package.json` and
lockfile were verified byte-identical to the candidate's. A `node_modules`
symlink supplied the exact compiler installation produced by candidate `npm ci`;
then `npm run typecheck` ran from that base directory. No candidate source or test
files were added to the base. This controls dependency differences in the comparison.

## Individual test results

All D/R results below are from actual execution. Positive controls are assertions
inside the same test and run before the deletion/refusal assertion. Printed
control/result lines are preserved verbatim in `targeted.log`.

| Arm | Observed result on preserved candidate |
| --- | --- |
| D1 | Passed: write authorization and HTTP 200 before deletion; `not_found` authorization and HTTP 404 after. |
| D2 | Passed: both SQL tables present before deletion and table counts zero afterward. |
| D3 | Passed: schema can be recreated in the same object after deletion. |
| R1 | `R1 CONTROL entry commit=200 frontier=200 writers=1`; then `R1 RESULT delete=204 same-write frontier=404`. |
| R2 | `R2 CONTROL write removal reached=204 read frontier=200`; then `R2 RESULT read delete=403 forbidden_scope surviving frontier=200`. |
| R3 | `R3 INERT never-created delete: registry count 0 -> 0`; first, repeated, never-created deletion all 204; non-root 404. |
| R4 registry failure | `R4 CONTROL frontier=200 registry row present=true`; then `delete=503 registry_delete_failed frontier=404 order=wipe,registry`. |
| R4 inert retry | `R4 RETRY absent-auth delete=204 registry row RETAINED=true events=wipe,registry`. |
| R4 storage failure | `R4 STORAGE FAILURE order=wipe_failed registry row retained=true frontier=200`. |
| R5 | `R5 CONTROL initial=0 before=2 both created rows present=true`; then `R5 RESULT before=2 after=1 delta=1 target absent=true other retained=true`. |
| R6 | `Test Files  22 passed (22)` and `Tests  308 passed (308)`; rc 0. |

The targeted run printed `Test Files  2 passed (2)` and `Tests  12 passed (12)`;
rc 0. It also exercised wrong/missing bearer, read scope, noncanonical paths,
revocation, both lane lifecycle-dispatch gates, and unbound-registry refusal.

## Tests demonstrated failing

### R4: remove the reviewer-adjudicated inert return

Temporarily removed only:

```ts
if (result === "not_found") return new Response(null, { status: 204 });
```

R4's control and first deletion/failure checks passed. The unauthenticated retry
then deleted the orphaned registry row. The unchanged test failed at line 247:

```text
AssertionError: expected true to be false // Object.is equality
expect((await registryKV.get(registeredId)) === null).toBe(false)
Test Files  1 failed (1)
Tests  1 failed | 8 skipped (9)
```

Process rc 1. Restoring the original source gave `1 passed | 8 skipped (9)`,
rc 0, with the retained-row control printed. Source restoration was checked
byte-for-byte; the application source also matches the preserved Git revision.

### Post-repair R4 repetition

The first R4 mutation above ran before the dispatcher-test row guards were added;
the repaired full suite then passed without mutation. Planner messages 29801/29805
required an explicit post-repair mutation before landing. That additional check
was run after boss-clod confirmed the assigned window in message 29811.

Starting from clean repaired commit
`629efde171f8305dbdb8e607c23ccecc7fc9ab95`, the same one-line inert-return
mutation again produced **rc 1**, `1 failed | 8 skipped (9)`, at unchanged R4
line 247: `expected true to be false`. Its initial frontier and ordered-deletion
controls passed before the failed retained-row assertion.

Application source was restored byte-for-byte and the repaired D-test was
verified unchanged throughout. The same R4 command then produced **rc 0**,
`1 passed | 8 skipped (9)`, printing:

```text
R4 RETRY absent-auth delete=204 registry row RETAINED=true events=wipe,registry
```

See `r4-postrepair-mutation.log`, `r4-postrepair-restored.log`, their direct process
status files, the mutation diff, and `r4-postrepair-identity.json` with the starting
commit, command, and source/test SHA256 values. The window was released in
boss-clod message 29813; the results were sent to the planner in message 29814.

### R2: make the removal route unreachable

Temporarily set the removal predicate to `false`, leaving R2 unchanged.
Its write-reachability control failed before read-scope assertions:

```text
WRITE DELETE / must reach removal before testing READ scope: expected 400 to be 204
Tests  1 failed | 8 skipped (9)
```

Process rc 1. This is a current mutation check; it does not reconstruct the
historical claim that R2 was authored before the original implementation.

### D2: prove the row-existence repair rejects an empty result

After the type repair, temporarily omitted the probe-row INSERT, leaving its
table and all expectations intact. D2 failed before the deletion:

```text
expected [] to have a length of 1 but got +0
Tests  1 failed | 2 skipped (3)
```

Process rc 1. The insertion was restored byte-for-byte. No optional chaining,
non-null assertion, cast, or relaxed expected value was used for the repair.

## Typecheck adjudication

| Revision | Status | Diagnostics |
| --- | --- | --- |
| Base `79edae4` | rc 2 | TS2307 at `read_capability.workers.test.ts:157:24` and `:158:29`, raw imports of `node.ts?raw` and `container.ts?raw`. |
| Preserved `9ff2646` | rc 2 | Both inherited errors, plus TS2532 at `delete_all.workers.test.ts:66:17` and `:99:14`. |
| Repaired tests | rc 2 | Exactly the two inherited TS2307 errors remain. |

The extra diagnostics are in the pre-written test supplied with the round, not
the removal implementation. Both commands returning rc 2 does not establish that
all candidate diagnostics predate the change. Planner message 29790 assigned the
TS2532 repair to this round and kept TS2307 outside it.

The repaired test retains the original `alpha` value assertion and table-count
checks, and adds exactly-one-row assertions plus explicit guards so TypeScript
can narrow the row type. Application source and R4 expectations are unchanged.

## Corpus and file scope

The original implementation prompt described a base plus an untracked supplied
test. Git's base itself contains **11** realm `.ts` files, not 12: the missing
twelfth is precisely `delete_all.workers.test.ts`. The preserved candidate has
13, adding that file and `realm_remove.workers.test.ts`.

At base/candidate respectively: registry file 51/58 lines; `deleteAll` textual
occurrences under worker source 0/3; public handler call sites 2/2. READ_ROUTES
contains the same four routes in both: `/frontier`, `/read-set`, `/read-writer`,
`/tail-local`. Registry interface adds `delete` beside `put`.

The preserved change has eight paths, listed in `changed-files.txt`. Beyond the
prompt's expected implementation paths, `worker/src/index.ts` forwards canonical
realm identity for removal; `registry.workers.test.ts` updates the existing fake
with `delete`; `delete_all.workers.test.ts` is the supplied D1–D3 test. All 15
existing `expect(` lines in the modified registry test are byte-identical to base;
all other pre-existing test files are unchanged. No gateway-token handling change
appears in the index diff. This verification round changes only the two unsafe
row-access sites in the newly supplied delete-all test, plus this report/evidence.

## Limits and follow-up

- Vitest logged request-stream exceptions during successful tests, plus runtime
  warnings. Raw logs retain them. Their cause and production relevance were not
  established by this round; a green test count does not resolve them.
- No deployed Cloudflare request, storage removal, registry operation, or merge
  was performed. All removal tests use local workerd test storage.
- D1/D3 no-op mutations described in the original prompt were not rerun here;
  their current positive runs are recorded without claiming new negative controls.
- Inherited TS2307 errors need a separate tracked fix. The planner must decide
  whether the remaining failure permits any landing; this report grants none.
