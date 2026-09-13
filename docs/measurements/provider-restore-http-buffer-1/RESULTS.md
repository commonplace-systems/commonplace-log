# Public ingress buffering results

The retained root run passed the focused public ingress buffering case. Root
session `35223` returned final receipt
`085b11` with outer rc `0`; the native Vitest and verdict
rcs were both `0`.

- Assertion: `public ingress body buffering rejects wrong-secret bodies, then serves inventory and restore, while bounding overflow before auth`
- Tests: 1 total, 1 passed, 0 failed, 0 pending, 0 todo
- Source archive HEAD: `ce0389c2947872c0d4b99bc314c673ccf7d0be7d`
- Fixture: `0c303e24a60a8dfae4368c2e6c9fe436fe984034`; SHA-256 `ab1cf917d37974962bdf9f14d1f5876a2bc9b8296fd3508f5f75e6bbd37585ea`
- Runtime membership: 3,221 files before and after; no additions or removals; input hash equality `true`
- Owned process group: PGID `1966416` exited `0` and was absent during finalization; TERM, KILL, timeout, signal, and forced cleanup were all false
- Stderr diagnostic count for the forbidden request-stream message: `0`; retained stderr contains only the Node `DEP0040` deprecation and Cloudflare containers sourcemap warnings

The complete selected raw output file list and SHA-256 values are in
[`output-manifest-1.json`](output-manifest-1.json). The raw receipt files remain
under `tmp/provider-restore-http-buffer-1`; this commit does not copy or mutate
them. Scope is local Vitest/Workerd testing through the actual `SELF` ingress
and `REALM_CONTAINER` path. It makes no cloud, deployment, account activation,
credential, production-route, or hard native-cancellation claim.
