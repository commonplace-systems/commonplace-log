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

A compliance check over all 32 current files (see "Sanity checks run at
seeding" below) passes; any task adding vectors must keep new files compliant.

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

Tasks adding vectors must re-run equivalent checks and update the SELECTOR
statement above.
