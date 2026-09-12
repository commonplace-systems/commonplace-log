# Local restore rehearsal boundary

This fixture is a synthetic primitive rehearsal, not an application backup or
restore implementation. It uses the exact `0749abb8` RealmStore and real
Durable Object SQLite test storage. It proves that supplied canonical bytes,
entry IDs, writer IDs, writer sequences, predecessor IDs, and tips can be
copied into an empty target, survive a simulated Durable Object restart, and
remain readable after a fresh lease and append.

The fixture admits an archive through a local verifier before calling
`RealmStore.commit`. The verifier checks canonical JSON/index agreement,
per-writer contiguous sequences, predecessor links, unique coordinates, and
frontier tips. This is deliberately fixture-local: the production Realm API
remains a low-level indexed-byte store and does not acquire a restore trust
contract here. The negative case demonstrates that malformed metadata is
refused while the target is still empty.

The synthetic archive is closed and contains only two writers and one log. It
does not enumerate or restore the application inventory: Directory documents,
Chit histories, review/candidate journals, memberships, revocations, and
external grants still require an explicit manifest/inventory API. Directory
closure alone cannot establish that inventory.

## Retained local result

The focused run was executed once after correcting an initial orchestration
path error that failed before Node started. The retained completion record is
`tmp/restore-rehearsal-1/root-tool-completion.json`: session `51276`, native
outer return code `0`, two tests passed, zero failed, and 10.91 seconds total.
It records fixture commit `11a3666` and package-lock SHA
`c58243da2b1d7e7fe64b079388e3c63bb6d9a30d21a9a2d2c9772df9f98b0947`, matching
the fixture lock. Vitest reported `v3.2.7`; the worker pool was the existing
local installation. The stderr record retains the expected workerd abort
diagnostic from the simulated restart plus dependency sourcemap/deprecation
warnings.

This result establishes only the bounded local RealmStore primitive: exact
synthetic rows can be admitted by the fixture verifier, restored into an empty
test target, read after a real test-runtime object restart, and extended with
fresh lease authority. It does not establish a production backup, portable
archive format, application inventory, deployed Worker behavior, or recovery
of Directory, Chit, journal, membership, grant, or revocation state.

## Retained validated-import result

The focused importer run was executed once from commit `c4781db` and is
recorded in `tmp/restore-archive-1/root-tool-completion.json`: session
`43557`, native exit code `0`, four tests passed, and 3.37 seconds total.
The pre/post input records are identical:

```text
9432cd1fbcd9745424ed2e66c1f3b3a28ffd3c08d818554126e51fed9e6926e3  test/realm/restore.archive.rehearsal.workers.test.ts
c58243da2b1d7e7fe64b079388e3c63bb6d9a30d21a9a2d2c9772df9f98b0947  package-lock.json
```

The test-only importer validates the actual entry/JCS contract, exports from
an explicitly supplied log through frontier and writer reads, preflights IDs
and coordinates, resumes missing rows, and refuses malformed, conflicting,
or unrelated-writer input before mutation. The shuffled second import is a
full remaining batch; it is not evidence of a bounded shuffled-prefix
checkpoint. This remains a local workerd/RealmStore rehearsal with no app
inventory, HTTP restore API, cloud restore, or whole-application claim.
