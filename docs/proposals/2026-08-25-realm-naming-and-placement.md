# Realm naming and placement — decision document

**Status:** proposal for jes, 2026-08-25. Nothing here is built; every option below is one Sol
round. The readiness document calls this "an owner's choice rather than an implementation
detail", so this records what exists, what is open, and one recommendation per question.

## What exists (measured on the deployed system, 2026-08-25)

- A realm is addressed by `realm_id` in the gateway path, `/realms/{realm_id}/…`, validated
  against `^[A-Za-z0-9._-]{1,128}$`, and resolved with `REALM_NODE.getByName(realm_id)`.
  `getByName` is deterministic: the same string is the same Durable Object everywhere, forever.
- One Durable Object per realm holds the realm's SQLite (many logs) and manages at most one
  container instance (`instance_type: lite`, `max_instances: 3`, no region constraints, default
  scheduling). A rollout does not preempt a running instance.
- The gateway's `realm_id` is the only authorization scope today: the bearer token is one
  secret for the whole deployment, and any holder can name any realm.
- Spec §6.1 allows a physical `scope_id` prefix; the amendment makes the realm database the
  default unit. Proposal §7.3 reserves a log→shard directory for later. None of that is built.
- `realm_id` never appears in an entry or a log id; it is physical placement only.

## Question 1 — what is a realm id?

| Option | Shape | Cost | Consequence |
|---|---|---|---|
| **1a. Opaque UUID, minted by whoever creates the realm** | `getByName(uuid)` | none | Unguessable, no rename problem, no meaning to leak. A directory above the log maps tenant → realm ids. |
| 1b. Human slug (`acme-prod`) | as today | none | Readable in URLs and logs; guessable; renaming a realm means migrating a DO, which the platform cannot do — a slug is forever. |
| 1c. Tenant-prefixed slug (`acme/prod`) | needs the regex widened | small | Encodes the tenant→realm relation in the id, which then cannot change. |

**Recommendation: 1a.** jes has said a tenant may have several realms and that a cell/log lives in
exactly one; that relation belongs in a directory, not in an immutable DO name. The current regex
already accepts UUIDs, so this is a naming convention plus a check that the id is a lowercase UUID
(one line) — or leave the regex alone and let the convention live in the caller.

## Question 2 — who may create a realm, and how is one created?

Today a realm exists the moment a request names it: `getByName` on an unseen id creates the DO,
and the first `/create-log` creates a database. There is no "create realm" act and no refusal.

| Option | Cost |
|---|---|
| **2a. Explicit `POST /realms/{id}` (create) and a marker in the DO; all other routes refuse an uncreated realm with 404** | one round: a `realms`-level row or KV flag in the DO, one route, tests for both arms |
| 2b. Keep implicit creation | none |

**Recommendation: 2a**, for the same reason doc's phase 18 moved to "open never creates": an
implicit create turns a typo into a new realm with its own container. The check is inside the DO,
so it is atomic by construction, and it is the natural place for a later "realm is closed/moved"
state.

## Question 3 — per-realm authorization

Today one bearer token opens every realm. That is fine for a development account and wrong the
day two tenants exist.

| Option | Cost |
|---|---|
| **3a. Per-realm secret, stored in the realm DO at create time, presented as the bearer; the gateway forwards it and the DO checks it** | one round; the check lives beside the data it protects, and rotating it is a DO write |
| 3b. Gateway-side map realm→secret (KV) | one round; a second store to keep consistent |
| 3c. Signed capability tokens naming a realm | larger; overlaps the spec's deferred "capabilities or signatures" |

**Recommendation: 3a**, combined with 2a (the create call returns the realm secret once). 3c is
the right long-term shape but is explicitly out of 0.1 scope, and 3a does not preclude it.

## Question 4 — placement

| Knob | Today | Note |
|---|---|---|
| region | unconstrained | `constraints.regions` accepts ENAM/WNAM/EEUR/WEUR/APAC/SAM/ME/OC/AFR; `jurisdiction: eu` exists. Placement is per **application**, i.e. per container class, not per realm. |
| instance type | `lite` (1/16 vCPU, 256 MiB) | enough for the experiments; a BEAM under real load wants `basic` or above. |
| max instances | 3 | the cap that stopped the third probe realm; production needs a number derived from expected concurrent realms, and a plan for what happens at the cap (today: HTTP 500 from the DO). |
| DO location | wherever `getByName` first ran | a Durable Object's home is fixed at first use; there is no per-realm pin today. `idFromName` + `locationHint` exists only for `get()`, not `getByName`. |

**Recommendation:** do not decide regions now. Add one thing: the create-realm call from 2a
accepts an optional `location_hint`, and the gateway uses `get(idFromName(id), {locationHint})`
for the *first* touch so a realm's home can be chosen at creation and is then fixed. Raise
`max_instances` to a deliberate number and make the at-cap failure a 503 with a clear code rather
than the platform's 500.

## Question 5 — sharding (§7.3)

Not now. One realm database is the ruled default; nothing measured approaches a limit.

## What this document does not decide

The reducer-level and doc-level meaning of a realm (cells, directories) is above this library and
unchanged by anything here. A `realm_id` remains physical placement, never authority.

## If jes rules for the recommendations

One Sol round on the Worker (create route + marker + per-realm secret + location hint + at-cap
503) and one small Elixir round (the deployed integration test gains a create-realm step and a
wrong-realm-secret arm), then a deploy and the same hand-run table as §4b.
