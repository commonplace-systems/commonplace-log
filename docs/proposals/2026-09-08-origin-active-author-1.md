# ORIGIN-ACTIVE-AUTHOR-1: current author call and first failure

Source-design proposal only, under Plan #34127 and the corresponding brief in
commonplace-plan. No implementation, product import, test, compilation, build,
runtime, live query, deployment or new user observation accompanies this proposal.
Implementation and another capture remain HOLD pending Next and Plan review.

## Evidence and source binding

The accepted 16:27Z origin is 998 bytes, SHA256
`44420057f2beceaed62ca913fa2e7a8641a88703d6f5016793c1f206d58406d2`.
Log's one receiver invocation returned complete/rc0; receipt SHA256
`5a8cf2133de01d3a07cc072f8fa438b2abe8d62817920ac3f034174d043c559e`.
Next's analysis is commit `03b6725`, document SHA256
`a4b4523c72fdf7349e834e6abb5e815a31803c54ee95dac0d9d9c4b72f4c283d`.
Client state is unavailable, with zero client receiver invocations. Original
inbound envelope/native-copy fidelity is not independently established here.

Attempt 5 initialized at 304ms; original callback at 5502ms and DOWN at 10504ms
classify an author-call timeout for B unequal selected S. Leave separately timed
out between 5502 and 10503ms. Armed generation 4, attempt 5 and current generation
26 remain distinct. Neither B's handler phases nor persistence/ACK outcome is
established. The target PID was not exported or identified by that classifier.

Read source from
`/home/jes/codex-save-state-1/tmp/origin-timeout-class-1`, tested product commit
`9e32f78c11c22a0565ddb0b24adab85d010b6ba2`, deployed tested image
`3b57a71ae2e9c6337bce7cb6057ccf23e1055003e817db4c06d9c96364a335b7`.
These four files have no diff from that commit at the reviewed docs descendant:

| File | SHA256 / relevant source |
| --- | --- |
| `lib/commonplace_next/diagnostics/origin_receipt.ex` | `bdf313ab8ec913081ff59b44fa70c14ea0b9f3b61c802d573ec786948b92fe2a`; reserve/bind/selected, two-attempt ETS CAS, fixed export |
| `lib/commonplace_next/web/yjs_socket.ex` | `d904e62b5d3618aff2659c139e331a3379f9229ef4712ecfea58607e3382bf14`; text call at 49, ACK callback at 73, termination at 94 |
| `lib/commonplace_next/yjs/attachment.ex` | `220b2ffc43e8133ab90a3ce3ceffb3bc04c7e868951d3a3d18845e3d578eac23`; exact insertion map below |
| `assets/src/origin-receipt.js` | `f0a6eaa0070f15d16af4d6b80f3fbb1f8d0a9aa6c5d716bfc3d7bfeaeb734831`; closed v1/v2 reader at 17–44 accepts no additional server keys |

## Decision and selection relevance

Keep S, the owner/token/document reservation, and its one bound socket/attempt.
Add one replaceable **current synchronous author-call record** on that socket.
After a call returns normally it may be replaced by the next author call. Freeze
the first call that raises/throws/exits, or returns `{:error, _}` to its caller.
For the reviewed socket path, either failure propagates into termination; there
is no later healthy call on that connection to prefer. A business refusal that
sends `{:refused, ...}` but returns `:ok` is recorded as a phase outcome and does
not freeze the call. It does not terminate this socket.

The record is active, returned, or frozen, mutually exclusively. No second live
record is needed once failure freezes it. This is stricter than the allowed one
active plus one frozen maximum. It follows healthy A to failing B; an arbitrary
first-author record could remain on A and miss B again. S-only observation already
missed B. No operation map, growing history, ring or new observer is proposed.

Freeze happens in the wrapper around the *original* `GenServer.call`, before
re-raising its original failure or returning its error. It precedes socket
termination, the leave call, and DOWN. Those existing independent records remain
untouched. Termination classification alone must not manufacture a missing
freeze or identify a call after a recorder gap. A non-author failure leaves the
last returned author explicitly returned, not falsely frozen as its cause.

## Private correlation without changing the request

Expand the body of `Attachment.handle_frame/3` around its existing single call.
Admission of the extra diagnostics requires `self() == client`, the already
bound socket, a currently recording receipt, a PID-valued attachment argument,
and the already-decoded author tuple with a bounded valid operation ID. The
live `Attachments.attach/3` returns a PID; other argument forms receive a gap
and execute unchanged, without an additional target lookup. Do not decode,
hash, copy or retain the update payload.

Before the call, bounded CAS installs an immutable private identity:
`{receipt_ref, call_ref, ordinal, socket_pid, attachment_pid, operation_id}`.
The receipt owns a saturating ordinal 1..65535 and one fixed gap primitive.
`make_ref()` supplies call identity; the ordinal is only its bounded public
label. The private operation ID is 36 bytes. None of the PID/reference/B-ID
values is serialized. Export only equality with S (`selected` or `other`).

At the very beginning of `handle_call({:frame, client, frame}, from, state)`,
before the joined-client test, claim the installed context by a second bounded
CAS. Require the actual `from` caller PID equals `client` and the bound socket,
`self()` equals the captured attachment PID, operation equality, the same
receipt/call references, active-or-frozen state, and no prior handler claim.
Use the context returned by that claim for all local phase publications.
Never look up a fresh context by operation ID inside later work.

This side-table correlation depends on an explicit source invariant: the socket
has one synchronous frame call outstanding, sends that original request exactly
once, and cannot start its next call before this one returns. A successful
`handle_call` finishes its inline work before its reply permits advancement.
A timeout does not cancel its request; freezing retains the sole outstanding
identity so queued work can still claim it later. An exception caught elsewhere
cannot enable another record: a frozen record is never replaced. This design
does not assert correlation for arbitrary raw/forged GenServer requests or
future asynchronous/delegated handlers. Changing that invariant requires review
or a protocol-carried call identifier, which is outside this proposal.

Successful completion changes active to returned under the same reference.
Only returned can advance to a fresh identity. Handler claims cannot use a
returned record. A failed completion CAS leaves active and inhibits subsequent
replacement; it never silently lends the identity to another operation. If
begin/claim/freeze cannot publish in two CAS attempts, latch a gap and proceed
with the unchanged application operation. No spin, mailbox request, extra
business read, retry, timer, monitor or blocking diagnostic call is added.

Ordinals never wrap: an attempted 65536th call latches overflow and disables
further author admission for this receipt. A stale captured context cannot
write a different call or receipt. Same-receipt stale publications latch a gap
without rewriting the current call; old-receipt publications cannot contaminate
the new receipt. Retired context values are fixed-size local terms, not retained
as a diagnostic collection. Application epoch/head changes do not rename the
call. Reuse of B's operation ID in a later successful call gets a new call_ref
and ordinal; after a frozen failure it cannot create another record.

## Source insertion and fixed phases

Retain the original selected-S marks as their existing aggregate evidence.
Carry a separate optional author context alongside the existing receipt through
private helper arguments. Do not change `{:frame, client, frame}`, GenServer.call
timeout/options, reply tuples, messages, payloads or business control flow.
Only explicitly enumerated diagnostic fields may be added to recorder state.

Each new phase has one entry and at most one terminal outcome. The existing
single head-change retry has its own second admission/persistence slots, so
first failure and later success do not overwrite or merge each other's times.
Repeated/conflicting writes to a completed slot latch a gap rather than replace
it. Identical repeated publication is an idempotent no-op.

| Index / phase | Insertion in `lib/commonplace_next/yjs/attachment.ex` | Meaning and limits |
| --- | --- | --- |
| 0 call | 34–35, around the original call only | Before-call publication; caller's normal result or original catch category. Entry precedes the actual send, so it alone does not prove dispatch. Failure freezes here. |
| 1 handler | 101–113, claim before `Map.has_key?` | Actual handler entry including not-joined; wrap original body and classify its original reply/catch. An entered handler has passed private identity checks. |
| 2 memory | 250–277, original authored-map lookup and immediate admission branches | Memory duplicate, reused ID, size/epoch refusal, or proceed. No additional lookup. Epoch refusal at 195–207 terminates handler as refused without claiming this phase ran. |
| 3 durable | 278 and 307–324 | Enter before existing durable duplicate lookup, terminal result from its original branches: duplicate, unknown-operation/not-duplicate, reused ID, or lookup-error. The latter still returns the existing `:not_duplicate`; do not turn swallowed host errors into business errors. The boundary includes existing content-commit verification, not just one storage lookup. |
| 4 admission1 | 326–338, first invocation | Existing commit preparation/options/before-store callback. Finish just before persistence entry; an unfinished interval does not identify a specific substep. |
| 5 persistence1 | 340–345, first invocation | Original put-and-select call result/catch; recognize existing head-changed and duplicate responses without modifying them. This is the Attachment-facing result, not an independent disk read. |
| 6 retry | 373–398 | Existing snapshot and reconciliation, finish before invoking admission2, or on original refusal/error branch. No extra retry. |
| 7 admission2 | 326–338, existing recursive attempt only | Private attempt index derived from the existing retries argument (initial 1, retry 0); no application retry-count change. |
| 8 persistence2 | 340–345, existing retry only | Separate outcome and time from persistence1. |
| 9 projection | 412–423 | Existing `Encoding.apply_update` boundary. Durable/memory duplicate paths skip this; absence is not failed projection. |
| 10 ack_enqueue | 255–257, 402, 424–426 | Same captured handler context around the existing `send`; any successful branch sends once. `ok` means send returned, not socket/client receipt. |
| 11 postenqueue | 409 or 428–433 | Existing status publication/encoding/fanout block. Failure here can coexist with an earlier successful ACK enqueue. |

For the handler terminal outcome, set one private monotone `refused` boolean
under the captured call identity at `refuse/6` (452–455), preserving its `:ok`
business result. The handler's terminal CAS reads that boolean: a normal reply
with the marker becomes diagnostic outcome7; an original catch/error retains
its own outcome. The refusal mark does not prematurely close the handler slot
or change a private helper's business return shape. A failed refusal publication
latches a gap. Existing nested wrappers must execute each original expression
once, return the exact original term, and on catch preserve kind/reason and the
captured `__STACKTRACE__` via `:erlang.raise`. Diagnostic failures are swallowed
and marked as gaps; they cannot replace an original result or exception.

### ACK callback is deliberately uncorrelated

The existing `{:ack, operation_id, head}` contains no call reference. A healthy
A can enqueue an ACK, return, and allow B to begin before A's ACK is handled.
Reused IDs also prevent a fresh socket/op lookup from distinguishing calls.
Therefore add **no author-context lookup or mark in YjsSocket's ACK callback**.
The new schema says `ackTuple: "unavailable"`. The old selected-S
`ack_callback_tuple` slot keeps its existing operation-level meaning and is
never joined to a particular new call ordinal. ACK enqueue is the last safely
correlated ACK boundary under the unchanged message protocol. Extending that
boundary requires a separately reviewed message identity or extra bounded
protocol, not an inferred association here.

## Lifetime, concurrency, and late work

Reuse the original reservation clock: recording stops at 180000ms; export
expires at 240000ms. One existing owner, row, timer and monitor remain. Fixed
new storage is one call record (12 fixed slots), one bounded ordinal, one
handler-claimed flag, one refusal boolean and one author gap bitmask; active and
frozen do not coexist. Successful history is discarded at advancement, not exported as a
trace. A first failure is immutable in identity, freeze time and failure kind;
its still-open phase slots may subsequently finish under that same context.

The caller may time out while its handler is queued or executing. After freeze,
the delayed handler may claim the retained identity even after caller death,
and continue publishing through the original stop time. It may report durable
success and `send` to a dead caller. No diagnostic cancels work, checks process
liveness to change behavior, restores a caller, or changes leave ordering.
Outcome timestamps after freeze or after recorded DOWN are late publications
under the same call identity. They do not prove client delivery, and completion
between actual death and delayed DOWN observation cannot be ordered by DOWN
alone. Phase times describe source boundaries, not scheduler or wire timestamps.

Each CAS operates on the latest whole receipt so concurrent existing S marks,
termination, and author phase marks cannot overwrite each other's accepted
updates. Retry the diagnostic CAS at most twice, then latch the gap. Export is
one bounded snapshot of the row plus its atomic gap indicators, not a promise
that another producer cannot publish or fail immediately afterward. Top-level
publicationGap also becomes true when author gaps are nonzero. A gap-free
snapshot does not prove no missing publication: an untrappable kill or recorder
loss can prevent even a gap latch.

At stop, do not extend recording for late work or update the expired context.
Open slots then remain unknown; `recording:false` states the cutoff. At expiry,
receipt replacement or recorder death, publication cannot be recovered; old
contexts cannot attach to a new receipt, socket, attempt or reused token/op.
Source producer exceptions are best-effort gaps, not universal loss detection.
Missing handler entry therefore leaves the send/queue/entry-publication boundary
unresolved; a later positively matched handler entry is evidence of admission.

## Closed v3 schema and budget

Server v3 retains all v2 fields and adds exactly `author`. The outer
origin-receipt-1 wrapper remains v1, and client diagnostics remain unchanged.
`author` has exactly these keys:

| Field | Closed type/meaning |
| --- | --- |
| `v` | Integer 1, version of this subrecord |
| `gaps` | Integer 0..255: bits 1 contention, 2 conflicting handler claim/identity, 4 ordinal overflow, 8 stale same-receipt call, 16 conflicting phase publication, 32 unsupported non-PID target, 64 inconsistent lifecycle, 128 caught producer failure |
| `ackTuple` | Literal `"unavailable"` |
| `call` | Null if none admitted; otherwise exact object below |

`call` has exactly `seq`, `relation`, `state`, `at`, `freeze`, `phases`.
`seq` is 1..65535; `relation` is `selected|other`; `state` is
`active|returned|frozen`; `at` is receipt-relative start 0..179999.
`freeze` is null except when frozen, then `[time, kind]` where time is in the
recording interval and kind is `timeout|exit|throw|exception|reply_error`.
It equals phase 0's terminal time and agrees with its failure outcome. Returned
means phase 0 returned `:ok`, even if a separately marked business refusal
occurred. A frozen call never becomes returned when its handler finishes later.

`phases` is an array of exactly 12 positions in the table's order. Each is null
or `[entryTime, terminalTime, outcome]`; terminalTime and outcome are both null
until finished. All times are integers 0..179999, entry >= call.at,
terminal >= entry, and <= the export's `at`. Call phase entry equals call.at.
Null means no retained mark, not that the phase did not execute. With a gap,
an exit publication may lack its entry and must leave that phase null rather
than fabricate an entry. Do not add counters, payloads, elapsed-time estimates,
operation IDs or free text.

Outcomes are integers: 1 ok, 2 error, 3 exit, 4 throw, 5 timeout, 6 not_joined,
7 refused, 8 duplicate, 9 not_duplicate, 10 lookup_error, 11 head_changed,
12 operation_reused. Codes describe the existing branch/result, not raw reasons.
Call phase allows 1..5; handler allows 1..8 and 12; memory allows 1..5,7,8,12;
durable allows 3,4,5,8,9,10,12; admission/retry allow 1..5,7;
persistence allows 1..5,8,11; projection allows 1..5,7;
enqueue/postenqueue allow 1..5. `exception` freeze maps to outcome2;
reply_error also maps to2. Missing entry on a failed publication is a gap,
not permission to weaken these phase shapes.

Static ASCII serialization accounting, with no product import or execution:

| Component | Conservative bytes |
| --- | ---: |
| Existing maximal v2 body (v3 digit same width), all 16 old slots | 1829 |
| New author value, all 12 triples populated | 388 |
| Comma/key/value addition `,"author":...` | 398 |
| Proposed server total | 2227 / 3072 |
| Existing maximal wrapper overhead (safe-integer generations) | 292 |
| Proposed origin total | 2519 / 4096 |
| Client cap | unchanged 8192 |

This is an upper bound, not an executable valid fixture: it conservatively
combines the longer `returned` state with a non-null freeze and every longest
slot value, even though a valid returned call has null freeze and some outcomes
cannot occur in every phase. All vocabulary is fixed ASCII; timestamps are six
digits, outcome codes at most two, ordinal five, gaps three. The new value uses
`relation:"selected"`, `freeze:[179999,"reply_error"]`, and 12 copies of
`[179999,179999,12]`. The existing budget's terminal239999 values have the same
six-digit width; the new schema permits recording timestamps only below180000.
Even a permitted full3072B server remains3364B with the existing wrapper. Keep
all hard guards and unavailable fallback; never truncate a structure to fit.

The current JS and Python closed readers reject v3 and extra keys. A later
implementation must extend those **existing schema readers** to admit exactly
v3 plus this schema, retain exact legacy v1/v2 acceptance, and reject unknown
versions, keys, enum values and malformed phases. This is a necessary
compatibility edit, not a new client observer, UI, query, transport or save
behavior. If even that existing-reader schema edit is excluded by the eventual
implementation grant, v3 cannot pass the current capture path: implementation
must remain held rather than label it v2 or silently strip author evidence.
No v1/v2 acceptance supplies active-author evidence. Structural complete is
independent of full phases: any existing loss flag or author.gaps yields partial;
null/in-progress phases remain explicitly unresolved even in complete exports.

## Finite proposed controls, not executed credit

The following ten control groups are proposed for a separately ranked stage.
Each uses finite fixtures and explicit cleanup; no live captures are proposed.

1. **Relevant failure:** selected S, healthy A, timed-out B != S. Require A's
   returned ordinal advances to B, B freezes before termination/leave, S is
   unchanged, and no later operation replaces B. Also cover B == S.
2. **Queue versus entry:** hold the Attachment before dispatch; caller timeout
   with no handler mark is unresolved. Release the same queued request and
   require its matched late handler entry under the frozen ordinal. Include
   not-joined at first entry and no fabricated earlier entry time.
3. **Healthy ACK before failure:** A sends ACK then returns, B starts/fails
   before A's ACK callback is processed. Include reused operation IDs. Require
   no B callback mark, unchanged ACK message, and ackTuple unavailable.
4. **Phase outcomes:** cover memory duplicate/reuse/refusal, durable hit,
   unknown-operation, generic lookup error preserving `:not_duplicate`, and
   failure inside existing durable verification. Verify no extra business read.
5. **Existing retry:** head-changed at persistence1, original snapshot/reconcile,
   then persistence2 success or refusal. Require distinct immutable timestamps,
   at most the original one retry, and no success overwriting the first failure.
6. **Late work and death:** timeout before handler entry and during persistence;
   continue after caller death through persistence/projection/enqueue/postenqueue
   on the captured context. Require original result/catch and bounded export
   interval, without interpreting send-to-dead-caller as delivery.
7. **Lifecycle/stale publication:** replay old call context after advancement,
   old receipt after replacement, reconnect, same operation ID, conflicting
   second handler claim, ordinal65535/overflow, and wrong private target/caller.
   Require no false join, no overwrite, and specified same-receipt gaps.
8. **Contention and observation loss:** exhaust each two-attempt CAS boundary,
   including begin, handler claim, close and freeze; prove unchanged original
   execution and inhibition of unsafe replacement. Kill a producer before its
   mark and confirm absence is not upgraded by publicationGap=false.
9. **Bounds and compatibility:** finite maximal valid server/origin specimens,
   structural negatives including duplicate keys and illegal phase outcomes;
   exact byte guards3072/3073 and4096/4097; legacy v1/v2 acceptance but no v3
   claims, all 12 fixed positions, cutoff180000/expiry240000, unchanged client8192.
10. **Original outcome fidelity:** enumerate ordinary `:ok`, returned error,
    raised exception, throw and timeout/other exit at each wrapper. Compare
    original values, kind/reason/stack, call/message counts and order against
    the uninstrumented path. Cover refused-but-`:ok` and post-enqueue failure.

No executed-test or runtime claim is made by these proposals or byte accounting.

## What would justify a repair

A matched late handler entry can narrow the queue/dispatch boundary; a matched
unfinished durable/admission/persistence/projection phase narrows the next source
investigation subject to loss and cutoff. A positive late persistence success
plus ACK enqueue after caller death supports completion-to-dead-caller on this
call. It does not identify the whole user-visible stall, prove selected S's
commit or ACK, or recover the absent client state. A durable lookup-error branch
would justify reviewing that existing error fallback, not silently changing it
in this instrumentation stage. Positive enqueue/normal postenqueue leaves
transport/client application unresolved because callback identity is unavailable.

Any repair still needs a concrete reproduced mechanism, its original outcome
and data-integrity requirements, and a separately ranked change. No automatic
timeout increase, asynchronous conversion, blind resend or persistence repair
follows from a missing slot or this design. The narrower attainable proposal
stops at call-correlated ACK enqueue; exact ACK callback correlation is its
explicit limitation under the unchanged message protocol.
