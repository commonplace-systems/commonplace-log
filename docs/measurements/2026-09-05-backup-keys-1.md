# BACKUP-KEYS-1: derived identifiers and the production output boundary

Base after fetch: `7c9d9ca16b418ac7c218e5827540d3fed3c8d7a8`.
Branch: `work/backup-keys-1-2026-09-05`.

## Decision and outcome

Choose **B**, explicitly ruled by commonplace-plan in message 29918: derived keys
remain, while contents and listings require membership-roster/document-inventory
confidentiality. [Design §10](../backup-design.md#10-decision-derived-backup-keys-are-sensitive-metadata-backup-keys-1)
and the backup README record the decision, both options' costs, and the mechanism's
limits. There is no backup runtime-source, object-layout, capability, live-config,
or deployment change. No live identity was guessed and no Cloudflare API or real
bucket was accessed.

The full suite passed **322 tests across 25 files**, seed **20260905**. Focused
backup types pass. Full typecheck returns 2 with only the same inherited TS2307
errors at read_capability.workers.test.ts:157/158. Complete logs and direct process
statuses are in the [checksummed evidence directory](2026-09-05-backup-keys-1/).

## D1: demonstrate the oracle rather than assume it

Read the brief before the prompt. The brief omits the membership namespace,
exact discriminator encoding and positive-control literals. Those are necessary
to reproduce the derivation. The other door's checkout lacked the pinned commit,
so a separate temporary bare clone supplied read-only Git objects for next
`94abc915604cf93ee6c604d33bc2e14ae2d61441`; its source blob identities are recorded
in `upstream-source.json`. The other working tree was not modified.

The source connects Cell.Supervisor's cell_id to the journal log_id, and
EditorPlacement.entry connects (organization, member, generation) to a membership
epoch and editor cell. The fixture helper implements the distinct membership and
identity namespaces, SHA256, first 16 bytes, UUID version/variant bits and format.
Before probing a listing it reproduces **nine literal Elixir-produced facet IDs
and one discriminated session ID** from the upstream stability test. Those
literals predate this helper and were captured at upstream b1842e1. An additional
`acme/alice/1` chain supplied by planner's independent Python implementation also
matches; it is attributed as Python-derived, not mislabelled an Elixir vector.

The test then creates an invented member's editor log with an entry and calls
`runBackup` against local DO/KV/R2 fixtures. From the resulting key names alone,
the same member/generation matches; a different member and a different generation
do not. The oracle working is the finding. It confirms guesses of historical
cells; it does not enumerate unknown members or establish a current roster.

A deliberate wrong namespace makes the known-vector assertion fail (rc 1) before
any inference about membership. `d1-broken-instrument.log` therefore represents a
broken instrument detected, not a finding of "no oracle." The helper was restored
byte-for-byte; the full suite subsequently passed its unchanged control and
oracle assertions. `d1-control.log`, the failed control and final log all remain.

## D2: costs and custody record

The brief's claim that losing an opaque mapping necessarily duplicates backups
was corrected before selection (planner 29910): fail-closed A instead stops with
a named outage until the mapping is recovered. The cost is a persistent custody
and availability dependency. Silent replacement is what would cause duplication.
A random realm prefix alone would still expose raw log IDs, and opaque entry keys
would not hide an unchanged manifest's identifiers from a manifest reader.

B preserves derivability and existing recovery semantics, but an index travelling
alone remains a disclosure. This is not dismissed because document contents are
more sensitive. The required policy forbids copying live indexes, manifests or
run payloads into channels, tickets or reports. Synthetic fixtures are labelled.

The brief calls for a cf-records decision while the prompt reserves those edits
to boss. Routed to boss rather than editing its tree: it recorded the provisional
position at `64618b1` and corrected A's price at `ea88be7`. The final decision
record was requested in message 29921 following planner's ruling. No effective
bucket access policy was inspected or changed here; no deployment authorization
is inferred from this decision.

## D4: reviewed source integrity, with a demonstrated failure

Read both production modules in full. Current I/O is realm reads and R2. The
scheduled handler returns no report and emits only a fixed stop code plus opaque
run ID on failure. The manifest, inventory and run payloads are not emitted to
console, HTTP responses, external endpoints or extra bindings by this code.

The boundary script now verifies a SHA256 manifest of the **complete production
source set**, rejects changed/missing/extra modules and symlinks, and prints the
excluded test/fixture/operator/provider paths. Its red message states exactly
which output paths must be reviewed before hashes change. It is an integrity
check on reviewed code, not semantic analysis or a sandbox for arbitrary future
code; changing hashes requires review and must not become a mechanical ritual.

A direct console-manifest mutation to the actual source makes the full boundary
script return 1. Byte-for-byte restoration makes it return 0. Additional isolated
fixture controls reject an aliased console sink and a new JS module, then pass
again on restored sources. These controls never print live data. The boundary
script's default comparison base advances to this round's 7c9d9ca: the earlier
b75ac47 predates the separately landed registry binding. Protected paths remain
unchanged against the actual round base.

A static check on the worker's source cannot prevent an operator copying a
manifest out by hand. It also does not establish provider telemetry policy or
prevent reviewers approving a bad hash update. Those paths are uncovered by
construction and remain custody/review obligations. Tests and evidence contain
invented fixtures, not production inventories.

## Scope and verification receipt

Changed production runtime source: **zero bytes**. Changed files are the backup
README, design addition, boundary script/checker/review manifest, one additional
backup fixture test/helper, one boundary test, and this report/evidence. D3 is
inapplicable because A was not chosen. D1 and D4 fail as described, then pass;
full suite 322/25, focused types 0, full types 2 inherited, and boundary 0.
`restorations.json` records the restored hashes. `implementation.diff` captures
all code/test/script/design changes before report/evidence packaging.
