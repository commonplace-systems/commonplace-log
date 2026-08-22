# Conformance Test Vectors

Shared test-vector corpus for the Commonplace Monotonic Log. Every runtime
implementation (TypeScript, Elixir, and any future one) must pass these vectors
**byte-for-byte**. The corpus is the single source of truth; implementations
are never the source of expected bytes.

## `canonical-json/` — RFC 8785 (JCS) canonicalization vectors

Each case is one directory: `canonical-json/NNN-short-name/` containing exactly:

- **`input.json`** — the input, authoritative **as raw bytes**. Harnesses must
  read this file as bytes and parse those bytes as a JSON text in their own
  runtime (a shared pre-parsed form is deliberately not provided: some future
  cases will not survive a parse/reserialize round trip).
- **`expected.hex`** — the bytes a correct canonicalizer must emit for that
  input, lowercase-hex encoded so no editor or VCS setting can mangle them.
  The hex encodes *exactly* the canonical output bytes; the file's trailing
  newline is file formatting, not part of the encoded output.

### File byte rules (every file must comply)

- `input.json`: UTF-8, no BOM, LF line endings only (no CR bytes anywhere),
  exactly one trailing LF. The trailing LF is insignificant whitespace per
  RFC 8259 and is consumed by the JSON parse.
- `expected.hex`: a single line of lowercase hex (`^[0-9a-f]+\n$`) — no
  whitespace, no separators, no uppercase — followed by exactly one LF.

A compliance check over the full corpus passed at seeding (see "Sanity checks
run at seeding" below); any task adding vectors must keep new files compliant.

Numbering policy: new cases take the next unused number in sequence; the `9xx`
range is reserved for deliberately-wrong cases (harnesses may exclude `9xx-*`
from their pass gate but must assert each one mismatches).

### SELECTOR statement — what a green run does and does not mean

A green run over this corpus means "correct over these input classes" and
nothing more. **Every task that adds vectors must update this statement.**

Input classes currently **covered**:

- Object key sorting by UTF-16 code units: ASCII (incl. empty key and case
  sensitivity), BMP keys across C0/Latin-1/general punctuation/presentation
  forms (the RFC's own sort test), an astral-plane key that must sort *before*
  U+E000..U+FFFF keys (distinguishes UTF-16 code-unit order from both
  code-point order and UTF-8 byte order), recursive sorting in nested objects
  and objects inside arrays, array order preservation.
- String escaping: the seven two-character escapes (`\b \t \n \f \r \" \\`),
  `\u00xx` lowercase-hex escapes for remaining control characters (incl.
  U+0000), escaped-solidus (`\/`) becoming literal `/`, and non-ASCII
  characters staying literal (U+0080, U+2028/U+2029, astral plane).
- Number serialization at the decimal/exponential boundaries: `1e20` (largest
  decimal-form power of ten), `1e21` (smallest exponential, `1e+21`), `1e-6`
  and `0.000001` (same double, two input spellings, identical output
  `0.000001`), `1e-7` (`1e-7`), `-0` (`0`), `9007199254740991` (max safe
  integer), plus the rounding/normalization values inside the RFC worked
  example (`333333333.33333329`, `1E30`, `4.50`, `2e-3`, `1e-27`).
- Literals `null` / `true` / `false`; whitespace-laden input producing
  whitespace-free output; top-level non-object values (bare strings, bare
  numbers); empty object and empty array (nested inside case 005).
- One complete, valid spec §7 log entry (case 016): all eight entry fields
  through the full pipeline (key sort incl. the `writer_id`/`writer_seq`
  shared-prefix pair, nested `body` object, UUID and RFC 3339 strings,
  integer fields). This is also the valid-entry anchor for the entry
  validator (see `invalid-entries/` below).
- Whitespace collapse at scale (case 017): the same entry padded with >1 MiB
  of inter-token whitespace, so raw input exceeds 1,048,576 bytes while the
  canonical form is 016's 327 bytes. Together with `invalid-entries/025` this
  pins that the spec §7.1 cap is measured on **canonical** bytes, not raw
  input bytes — entry validators must accept 017.
- Float-spelled integer fields (case 018): the same entry with
  `"writer_seq": 27.0` and `"version": 1.0` — the same doubles, canonical
  form again 016's exact bytes. Pins that integer-field semantics are
  VALUE-based (see the `invalid-entries/` integer-field rule below) — entry
  validators must accept 018.

Input classes deliberately **not covered** (yet):

- Invalid inputs of any kind (malformed JSON, NaN/Infinity, ill-formed UTF-8):
  a later `invalid-entries/` task owns rejection behavior.
- Lone/unpaired surrogates in strings or keys.
- Duplicate object keys.
- Numbers needing full Ryu/Grisu coverage: subnormals (`5e-324`), extremes
  (`±1.7976931348623157e+308`), round-to-even ties, integers beyond ±2^53-1.
  Only the boundary values above are pinned.
- Deep nesting / resource-limit behavior.
- Top-level bare literals (`null` alone as a full input).

### Red-demonstration case: `999-deliberate-mismatch/`

`999-deliberate-mismatch/expected.hex` is **intentionally wrong**. The input is
`{"b": 2, "a": 1}`; a correct canonicalizer emits `{"a":1,"b":2}`, but the
stored expected bytes encode the unsorted `{"b":2,"a":1}`. Any byte-diff
harness run over the full corpus **must report exactly this one case as
failing**. Watch it go red before trusting any green: a harness that shows 999
passing — or shows all-green including 999 — is broken (wrong referent, not
actually comparing, or comparing a thing to itself). Harnesses may then
exclude `999-*` from their pass/fail gate, but should still assert that it
mismatches.

### How expected bytes were derived (provenance)

No third-party JCS implementation was used anywhere — the corpus must not
inherit another implementation's bugs. Expected bytes come from exactly three
sources, and the throwaway derivation script (not committed, by design) used
no algorithmic key sorter: key orders were hard-coded by hand per RFC 8785
§3.2.3 and only single-primitive serialization was delegated to node:

1. **RFC 8785 itself** (fetched from https://www.rfc-editor.org/rfc/rfc8785):
   the §3.2.2 input, §3.2.3 sorted form and sort test data, the §3.2.4 output
   hex dump, and the Appendix B number table.
2. **node v24.13.1 primitives**: `JSON.stringify` applied to *single* strings
   and numbers. Legitimate as reference because RFC 8785 defines string
   escaping (§3.2.2.2) and number serialization (§3.2.2.3) as exactly
   ECMAScript's `JSON.stringify` / `Number::toString`. Actual outputs used:

   ```
   006: JSON.stringify -> "\b\t\n\f\r\"\\/"
   007: JSON.stringify -> "\u0000\u0001\u000b\u001f"
   009-num-1e20: JSON.stringify(1e20) -> 100000000000000000000
   010-num-1e21: JSON.stringify(1e21) -> 1e+21
   011-num-1e-6: JSON.stringify(1e-6) -> 0.000001
   012-num-0.000001: JSON.stringify(0.000001) -> 0.000001
   013-num-1e-7: JSON.stringify(1e-7) -> 1e-7
   014-num-minus-zero: JSON.stringify(-0) -> 0
   015-num-max-safe-int: JSON.stringify(9007199254740991) -> 9007199254740991
   ```

   The three of these values that appear in RFC 8785 Appendix B (`1e+21`,
   `0.000001`, `0` for minus zero) match the RFC's table rows exactly.
3. **Hand derivation** of key order against §3.2.3's UTF-16 code-unit rule,
   shown per case below.

Cross-check for source consistency: case 001's bytes are the RFC's own §3.2.4
hex dump, and an independent reconstruction from node primitives plus the
RFC-stated key order reproduced those bytes exactly
(`001 cross-check OK: RFC 3.2.4 hex == node-primitive reconstruction`).

### Case list and per-case provenance

| Case | Exercises | Provenance |
|---|---|---|
| `001-rfc-worked-example` | Full pipeline: whitespace removal, number rounding/normalization (`333333333.33333329`→`333333333.3333333`, `1E30`→`1e+30`, `4.50`→`4.5`, `2e-3`→`0.002`, `1e-27`), string unescaping/re-escaping, key sort, literals | RFC 8785 §3.2.2 input, §3.2.4 output hex verbatim; cross-checked against node-primitive reconstruction |
| `002-rfc-sort-order` | UTF-16 key sort across U+000D, `1`, U+0080, U+00F6, U+20AC, U+D83D U+DE00, U+FB33 (the emoji sorts before the BMP presentation form) | Key order stated verbatim in RFC 8785 §3.2.3; each key/value serialized via node `JSON.stringify` on single strings |
| `003-sort-basic-ascii` | Empty key first; shorter-prefix-first (`a` < `aa` < `ab`); case sensitivity (`A` 0x41 < `a` 0x61) | Hand-derived: `""` < `"A"`[0041] < `"a"`[0061] < `"aa"` < `"ab"` < `"b"`[0062] |
| `004-sort-astral-before-e000` | **Astral key sorts before U+E000..U+FFFF keys.** UTF-16 code units compared by hand: `"z"`=[007A] < U+10000=[D800,DC00] < U+E000=[E000] < U+FFFD=[FFFD], because surrogate D800 < E000. Code-point order and UTF-8 byte order (7A; EE 80 80; EF BF BD; F0 90 80 80) would both put U+10000 *last* — an implementation sorting by either fails this case. Expected byte order verified by inspecting the decoded hex: `7a`, then `f0908080`, then `ee8080`, then `efbfbd`. | Hand-derived against RFC 8785 §3.2.3 as shown; values serialized via node `JSON.stringify` on single strings |
| `005-sort-nested-recursive` | Recursive key sort in nested objects and in objects inside arrays; array element order preserved; empty `{}` and `[]` | Hand-derived (all-ASCII keys: `a`<`z`; `aa`<`b`<`c`; `a`<`b`) |
| `006-escape-two-char` | All seven two-char escapes; `\/` in input becomes literal `/` | node: `JSON.stringify` output pasted above |
| `007-escape-u00xx-control` | Controls without two-char escapes → `\u0000 \u0001 \u000b \u001f` (lowercase hex); input's uppercase `\u000B`/`\u001F` normalize to lowercase | node: `JSON.stringify` output pasted above |
| `008-string-unicode-literal` | Escaped non-ASCII input (U+20AC `€`, U+1F600 `😀`, U+0080, U+2028, U+2029, U+1D11E `𝄞`) emitted as literal unescaped UTF-8 | node: `JSON.stringify` on the single string; output contains no backslashes, 25 bytes |
| `009-num-1e20` | Largest power of ten in decimal form → `100000000000000000000` | node output pasted above |
| `010-num-1e21` | Smallest power of ten in exponential form → `1e+21` (note the `+`) | node output pasted above; matches RFC 8785 Appendix B row `444b1ae4d6e2ef50` |
| `011-num-1e-6` | `1e-6` input spelling → decimal `0.000001` | node output pasted above; matches Appendix B row `3eb0c6f7a0b5ed8d` |
| `012-num-0.000001` | Same double as 011, decimal input spelling — expected bytes identical to 011, proving input spelling is irrelevant | node output pasted above |
| `013-num-1e-7` | First exponential-form small number → `1e-7` | node output pasted above |
| `014-num-minus-zero` | `-0` → `0` | node output pasted above; matches Appendix B row `8000000000000000` |
| `015-num-max-safe-int` | `9007199254740991` (2^53−1) round-trips unchanged | node output pasted above |
| `016-spec-example-entry` | Full valid spec §7 example entry: eight-field key sort (`body` < `created_at` < `entry_id` < `log_id` < `prev_entry_id` < `version` < `writer_id` < `writer_seq`; the last pair decided at `'i'` 0x69 < `'s'` 0x73 after the shared `writer_` prefix), nested `body` key sort (`type` < `value`), whitespace removal | Input is the spec §7 example verbatim. Expected bytes derived 2026-08-21 (node v24.13.1) by the same discipline as the seeding: key order hand-derived per RFC 8785 §3.2.3 as shown, single strings/numbers serialized via node `JSON.stringify`, concatenated by hand — `worker/src/jcs.ts` deliberately not consulted (it is under test by this vector). Canonical form is 327 bytes; the derivation script asserted the canonical text parses deep-equal to `input.json` (`VALUE-EQ OK`) |
| `017-whitespace-padded-entry` | Raw input > 1 MiB of inter-token whitespace collapsing to the 327-byte canonical form of 016 — cap-side discrimination: the entry-size cap measures canonical bytes | Input is 016's `input.json` with 1,048,600 spaces injected after the opening brace (raw size 1,048,977 bytes); `expected.hex` is a **deliberate byte-for-byte copy of 016's** (same canonical form, same reasoning as the 011/012 duplication), verified byte-identical with `cmp`; generation script asserted the padded input parses deep-equal to 016's (`VALUE-EQ OK`) |
| `018-float-spelled-integers` | Float-spelled integer fields (`27.0`, `1.0`) parse to the same doubles as `27`, `1` and canonicalize to 016's exact 327 bytes — input spelling is irrelevant (same philosophy as 011/012); doubles as the value-based integer-field acceptance pin for entry validators | Input is 016's `input.json` with the two literal spellings substituted as raw text (generation script asserted both substitutions applied and the result parses deep-equal to 016's, `VALUE-EQ OK`); `expected.hex` is a **deliberate byte-for-byte copy of 016's**, verified with `cmp` |
| `999-deliberate-mismatch` | **Intentionally wrong expected bytes** (unsorted `{"b":2,"a":1}` instead of correct `{"a":1,"b":2}`) — the red-demonstration case, see above | Wrongness constructed and verified at derivation time: stored bytes differ from the hand-derived correct canonical form |

### Sanity checks run at seeding (2026-08-21, node v24.13.1)

1. Every `expected.hex` round-trips `xxd -r -p` → `xxd -p` unchanged, and its
   decoded bytes are valid UTF-8 (`iconv -f UTF-8 -t UTF-8`): 16/16 `RT-OK
   UTF8-OK`.
2. For every case except 999: decoded expected bytes parse as JSON, and the
   parsed value deep-equals the parsed `input.json` (for 014, the sign check
   was done explicitly: input parses to `-0`, expected to `+0`): 15/15
   `PARSE-OK VALUE-EQ`.
3. 999: decoded expected bytes were compared against the correct canonical
   form and confirmed different (`{"b":2,"a":1}` vs `{"a":1,"b":2}`).
4. File byte rules verified over all 32 files (BOM, CR, trailing-LF,
   UTF-8 validity, hex format): 0 failures; the checker was demonstrated to
   fire on a known-bad file (missing trailing LF) before its green was
   trusted.

Tasks adding vectors must re-run equivalent checks, update the SELECTOR
statement above, and add a row to the "Case list and per-case provenance"
table.

### Checks re-run when adding case 016 and `invalid-entries/` (2026-08-21, node v24.13.1)

1. Byte-rule checker over both families — BOM, CR, single trailing LF, UTF-8
   validity, `expected.hex` format, `error.txt` format, input parseability:
   `checked 84 files, 0 failures` (17 canonical-json cases × 2 files + 25
   invalid-entries cases × 2 files). The checker was first demonstrated to
   fire on a known-bad corpus (missing trailing LF; uppercase `error.txt`):
   2/2 failures reported, exit 1.
2. 016 value equality: the derived canonical text parses deep-equal to
   `input.json` (asserted inside the derivation script, `VALUE-EQ OK`).

### Checks re-run for the spec-review fixups (cases 017, 026-029; 2026-08-21)

Byte-rule checker over both families after adding the five fixup cases:
`checked 94 files, 0 failures` (18 canonical-json cases × 2 files + 29
invalid-entries cases × 2 files); the checker was again shown red on the
known-bad corpus first (2/2 failures, exit 1). `017/expected.hex` confirmed
byte-identical to `016/expected.hex` with `cmp`; the padded input asserted
deep-equal to 016's on parse (`VALUE-EQ OK`).

### Checks re-run for the quality-review fixups (cases 018, 030; 2026-08-22)

Byte-rule checker over both families: `checked 98 files, 0 failures`
(19 canonical-json cases × 2 files + 30 invalid-entries cases × 2 files);
red-demonstrated on the known-bad corpus first (2/2 failures, exit 1).
`018/expected.hex` confirmed byte-identical to `016/expected.hex` with
`cmp`; 018's input asserted deep-equal to 016's on parse (`VALUE-EQ OK`).

## `invalid-entries/` — version-1 entry rejection vectors

Vectors for the spec §7 / §7.1 entry validator: inputs that every runtime's
`validate_entry` must **reject**, each with the exact error code and a shared
reason slug both runtimes must emit identically. The valid-entry anchor is
`canonical-json/016-spec-example-entry`, which validators must **accept**,
producing exactly its `expected.hex` canonical bytes.

Each case is one directory: `invalid-entries/NNN-short-name/` containing
exactly:

- **`input.json`** — the would-be entry, authoritative **as raw bytes**.
  Harnesses read the bytes and feed them to their validator unmodified.
- **`error.txt`** — exactly two lines, each followed by one LF:
  - line 1: the expected spec §11.6 error code (`invalid_entry` or
    `entry_too_large` in the current corpus);
  - line 2: a shared reason slug (`^[a-z0-9-]+$`), e.g.
    `missing-field-writer-id`. Reason slugs are cross-runtime contract: both
    the TypeScript and Elixir validators must emit the same slug for the same
    violation, byte-for-byte.

File byte rules are the same as `canonical-json/` (UTF-8, no BOM, LF-only,
exactly one trailing LF). Every current `input.json` is syntactically valid
JSON — these cases exercise entry validation, not JSON parsing. The numbering
policy is the same (next unused number; `9xx` reserved for deliberately-wrong
cases — none exist in this family yet).

**Determinism rule:** each case targets one violation, and validators must
check fields in the spec §7 table order (`version`, `log_id`, `entry_id`,
`writer_id`, `writer_seq`, `prev_entry_id`, `created_at`, `body`),
required-key presence before value checks, so any input gets a deterministic
slug. "One violation" is not always literally achievable: in `013`/`014` the
invalid `writer_seq` unavoidably interacts with the `prev_entry_id` rule
(when `writer_seq` is itself invalid, *any* `prev_entry_id` value is
arguable; those cases carry `null`). The declared table order resolves this
deterministically: `writer_seq` is checked first, so its slug is the answer.
Additionally, parse-time number-lexical violations (`invalid_json`,
`unsafe-integer`, `non-finite-number`) are detected before all field checks,
so a multi-violation input containing one of those yields the number slug
first — ports must match that ordering.

**Integer-field rule (value-based):** for `writer_seq` and `version`, the
JSON spelling is irrelevant — exactly the philosophy cases 011/012 pin for
canonicalization, and `canonicalize()` emits identical bytes for `27.0` and
`27` anyway, so accepted entries are byte-identical either way. What matters
is the VALUE: it must be a safe integer (integral, |v| ≤ 2^53−1), then
`writer_seq ≥ 1` / `version = 1`. In TypeScript this is
`Number.isSafeInteger`; the Elixir mirror is
`is_integer(v) or (is_float(v) and v == trunc(v))` plus the safe-range
bound — no tokenizer needed. So `27.0` is a valid `writer_seq`
(`canonical-json/018`) while `1e30` — an integral double beyond the safe
range — is rejected as `writer-seq-not-integer` (case 030). This is
deliberately different from the **body big-int rule (case 022), which is
lexical**: a plain integer literal that would lose precision at parse is a
different hazard from a float-spelled field, and is detected from the raw
token, not the parsed value.

Notes on individual behaviors:

- **`023-non-finite-number` (`1e999`)**: runtimes may detect this at parse
  time or post-parse (JavaScript's `JSON.parse` yields `Infinity`; other
  parsers may overflow or reject at decode). Either detection point is
  conforming, but the emitted code+reason must be identical:
  `invalid_entry` / `non-finite-number`.
- **`022-unsafe-integer-in-body` (`9007199254740993`)**: the violation lives
  in the raw token, not the parsed value — ECMAScript `JSON.parse` silently
  rounds it to the safe `9007199254740992`, so a post-parse safe-integer
  check can never fire. JS validators must inspect the raw literal (e.g. the
  `JSON.parse` reviver `context.source` argument, node >= 21). Only plain
  integer literals (no fraction or exponent) are checked against
  ±(2^53−1); exponent spellings such as `1e30` denote doubles and remain
  valid (case `001-rfc-worked-example` depends on that).
- **`created_at`**: the spec requires a "UTC RFC 3339 timestamp". This corpus
  pins the strict reading: only the `Z` suffix form is valid. A numeric
  offset — even `+00:00` — is rejected as `created-at-not-utc`, so both
  runtimes accept exactly one spelling of each instant.
- **`028-created-at-calendar-invalid` (`2026-02-30`)**: RFC 3339's
  `date-mday` grammar is constrained by month and year, so a
  calendar-invalid day IS not-RFC 3339 — slug `created-at-not-rfc3339`.
  Validators must use real calendar arithmetic (days-in-month plus leap-year
  rules); ECMAScript's `Date.parse` is disqualified as a backstop because it
  rolls invalid days over (2026-02-30 parses as March 2) instead of
  rejecting them.
- **`029-created-at-leap-second` (`23:59:60`)**: RFC 3339 itself *permits*
  second value 60, but this corpus rejects it **by policy**, with the
  dedicated slug `created-at-leap-second`: the one-spelling-per-instant
  discipline above, plus the fact that date libraries across runtimes
  disagree wildly on leap-second handling, make accepting `:60` a
  cross-runtime divergence hazard. The distinct slug (rather than
  `created-at-not-rfc3339`) records that this is a policy rejection of a
  grammatically valid timestamp.
- **`025-entry-too-large`**: its `input.json` is ~1.0 MiB of deterministic
  padding (`"pad"` = 1,048,576 repeated `a` characters) and is committed
  as-is; the canonical form is 1,048,867 bytes, over the spec §7.1 cap of
  1,048,576.

### SELECTOR statement — what a green run over `invalid-entries/` means

Violation classes currently **covered** (one case each unless noted): every
required top-level field missing (8 cases, incl. the `prev_entry_id` key
absent entirely); wrong `version`; extra top-level field; non-lowercase UUID;
malformed UUID in `entry_id`, `writer_id`, and a non-null `prev_entry_id`
(3 cases, same slug); `writer_seq` zero / negative (2 cases, same slug),
non-integer (1.5), and integral-but-unsafe (`1e30`, same slug as 1.5 —
the value-based integer-field rule above, whose acceptance side is
`canonical-json/018`); `prev_entry_id` non-null at `writer_seq` 1 and null at
`writer_seq` > 1; `created_at` with a non-UTC offset, non-RFC 3339,
calendar-invalid day (real days-in-month/leap-year validation), and a leap
second (rejected by policy, own slug); `body` array and string (2 cases,
same slug); integer literal beyond +(2^53−1) in `body`; non-finite number
literal; lone surrogate escape in a `body` string; canonical form over
1 MiB (whose complement — over-1 MiB *raw* input with a small canonical
form — is pinned valid by `canonical-json/017`).

Violation classes deliberately **not covered** (yet):

- **`log_id` differing from the target log**: excluded by design. Log-match
  (spec invariant 8) is a store-level check requiring context — the target
  log's identity — that a standalone entry validator does not have. It is
  owned by the store/merge conformance layer, not this family.
- Syntactically invalid JSON and ill-formed UTF-8 input bytes
  (`invalid_json`): every current input parses; parse-failure vectors would
  need per-runtime parse-error tolerance decisions not yet made.
- Duplicate object keys (I-JSON violation; most parsers silently keep one).
- Lone surrogates in object *keys* (covered only in string values).
- Lone surrogates in **non-body** string values (e.g. inside `created_at`):
  both runtimes reject the entry, but the slug differs by detection stage
  (TypeScript reaches the field check → `created-at-not-rfc3339`; Jason
  rejects at decode → `ill-formed-unicode`). Unpinned; only body strings
  (024) are pinned.
- Relative ordering **among** multiple parse-time number violations in one
  document (e.g. an unsafe integer literal *and* a non-finite literal):
  which of the two slugs wins is detection-order-dependent and differs
  across runtimes and across key order. Only their joint precedence over
  all field checks is pinned (ordering rule above).
- Multi-violation inputs pairing a runtime-fatal-but-elsewhere-tolerable
  token with a later grammar error (e.g. `{"a":1e999,"b":}`): the
  divergence here is **code-level**, not just the slug — Jason halts at the
  number token, so Elixir returns `invalid_entry` / `non-finite-number`,
  while V8 tolerates `1e999` (parsing it to `Infinity`) and throws at the
  grammar error, so TypeScript returns `invalid_json` / `not-json`. Both
  runtimes reject the entry; pinning one answer would force a runtime to
  restructure its parser for no interop gain, so this class stays unpinned.
- Negative integer literals below −(2^53−1) (only the positive side is
  pinned). Unsafe *values* in `writer_seq` are pinned by 030, but a plain
  unsafe integer literal there (e.g. `9007199254740993` as `writer_seq`)
  has no vector — the parse-time lexical check fires first, making the
  expected slug `unsafe-integer`, per the ordering rule above.
- Wrong top-level *types* beyond those listed (e.g. `version` as string
  `"1"` — rejected by the version check, but no vector pins its slug);
  non-object top-level entries (bare array/string).
- UUID version/variant bits: any `8-4-4-4-12` lowercase hex string is
  accepted; UUIDv7-ness is not checked (the spec only recommends v7).
- Fractional-second precision limits in `created_at`: **unpinned**. No
  vector constrains how many fractional digits are accepted (or whether an
  empty fraction like `12:00:00.Z` is tolerated by a lenient parser), and
  implementations may currently differ there.

### Case list

| Case | Code | Reason slug |
|---|---|---|
| `001-missing-version` | `invalid_entry` | `missing-field-version` |
| `002-missing-log-id` | `invalid_entry` | `missing-field-log-id` |
| `003-missing-entry-id` | `invalid_entry` | `missing-field-entry-id` |
| `004-missing-writer-id` | `invalid_entry` | `missing-field-writer-id` |
| `005-missing-writer-seq` | `invalid_entry` | `missing-field-writer-seq` |
| `006-missing-created-at` | `invalid_entry` | `missing-field-created-at` |
| `007-missing-body` | `invalid_entry` | `missing-field-body` |
| `008-missing-prev-entry-id` | `invalid_entry` | `missing-field-prev-entry-id` |
| `009-version-2` | `invalid_entry` | `wrong-version` |
| `010-extra-top-level-field` | `invalid_entry` | `extra-top-level-field` |
| `011-uppercase-log-id` | `invalid_entry` | `uuid-not-lowercase` |
| `012-malformed-entry-id` | `invalid_entry` | `uuid-malformed` |
| `013-writer-seq-zero` | `invalid_entry` | `writer-seq-not-positive` |
| `014-writer-seq-negative` | `invalid_entry` | `writer-seq-not-positive` |
| `015-writer-seq-non-integer` | `invalid_entry` | `writer-seq-not-integer` |
| `016-prev-not-null-at-seq-1` | `invalid_entry` | `prev-entry-id-not-null-at-seq-1` |
| `017-prev-null-after-seq-1` | `invalid_entry` | `prev-entry-id-null-after-seq-1` |
| `018-created-at-non-utc-offset` | `invalid_entry` | `created-at-not-utc` |
| `019-created-at-not-rfc3339` | `invalid_entry` | `created-at-not-rfc3339` |
| `020-body-array` | `invalid_entry` | `body-not-object` |
| `021-body-string` | `invalid_entry` | `body-not-object` |
| `022-unsafe-integer-in-body` | `invalid_entry` | `unsafe-integer` |
| `023-non-finite-number` | `invalid_entry` | `non-finite-number` |
| `024-lone-surrogate` | `invalid_entry` | `ill-formed-unicode` |
| `025-entry-too-large` | `entry_too_large` | `canonical-bytes-over-1mib` |
| `026-writer-id-malformed` | `invalid_entry` | `uuid-malformed` |
| `027-prev-entry-id-malformed` | `invalid_entry` | `uuid-malformed` |
| `028-created-at-calendar-invalid` | `invalid_entry` | `created-at-not-rfc3339` |
| `029-created-at-leap-second` | `invalid_entry` | `created-at-leap-second` |
| `030-writer-seq-1e30` | `invalid_entry` | `writer-seq-not-integer` |

Provenance: every input is the spec §7 example entry with exactly one
scripted, deterministic mutation applied as raw text (never re-serialized
through a JSON encoder, so lexical details like `1.5`, `1e999`, `\ud800`, and
`9007199254740993` are byte-exact). `error.txt` contents were assigned by
hand from spec §7/§7.1/§11.6.
