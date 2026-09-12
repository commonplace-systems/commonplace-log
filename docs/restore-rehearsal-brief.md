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
