/**
 * Version-1 entry validation (spec §7 shape, §7.1 I-JSON constraints, 1 MiB
 * canonical-size cap). The shared conformance corpora in
 * conformance/canonical-json/ and conformance/invalid-entries/ are the
 * arbiters of correctness; error codes and reason slugs are cross-runtime
 * contract and must match error.txt vectors exactly.
 */
import { canonicalize } from "./jcs";

export type ValidateEntryResult =
  | { ok: true; canonicalBytes: Uint8Array }
  | {
      ok: false;
      code: "invalid_entry" | "entry_too_large" | "invalid_json";
      reason: string;
    };

/**
 * Reason slugs shared with every other runtime implementation. Keep this the
 * only place they are spelled; each conformance/invalid-entries case's
 * error.txt pins one of them.
 */
const REASONS = {
  notUtf8: "not-utf-8",
  notJson: "not-json",
  entryNotObject: "entry-not-object",
  missingField: (field: FieldName) =>
    `missing-field-${field.replaceAll("_", "-")}`,
  wrongVersion: "wrong-version",
  extraTopLevelField: "extra-top-level-field",
  uuidNotString: "uuid-not-string",
  uuidNotLowercase: "uuid-not-lowercase",
  uuidMalformed: "uuid-malformed",
  writerSeqNotNumber: "writer-seq-not-number",
  writerSeqNotInteger: "writer-seq-not-integer",
  writerSeqNotPositive: "writer-seq-not-positive",
  prevEntryIdNotNullAtSeq1: "prev-entry-id-not-null-at-seq-1",
  prevEntryIdNullAfterSeq1: "prev-entry-id-null-after-seq-1",
  createdAtNotString: "created-at-not-string",
  createdAtNotRfc3339: "created-at-not-rfc3339",
  createdAtNotUtc: "created-at-not-utc",
  bodyNotObject: "body-not-object",
  unsafeInteger: "unsafe-integer",
  nonFiniteNumber: "non-finite-number",
  illFormedUnicode: "ill-formed-unicode",
  canonicalBytesOver1MiB: "canonical-bytes-over-1mib",
} as const;

const MAX_CANONICAL_BYTES = 1_048_576; // 1 MiB, spec §7.1

/** Spec §7 field table order; checks run in this order, deterministically. */
const REQUIRED_FIELDS = [
  "version",
  "log_id",
  "entry_id",
  "writer_id",
  "writer_seq",
  "prev_entry_id",
  "created_at",
  "body",
] as const;
type FieldName = (typeof REQUIRED_FIELDS)[number];

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
// RFC 3339 date-time restricted to the Z (UTC) offset form the spec's example
// uses; any numeric offset — including +00:00 — is rejected as not-utc so both
// runtimes accept exactly one spelling of each instant.
const RFC3339_UTC_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;
const RFC3339_OFFSET_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?[+-]\d{2}:\d{2}$/;

function invalid(reason: string): ValidateEntryResult {
  return { ok: false, code: "invalid_entry", reason };
}

export function validateEntry(raw: Uint8Array): ValidateEntryResult {
  let text: string;
  try {
    text = new TextDecoder("utf-8", { fatal: true }).decode(raw);
  } catch {
    return { ok: false, code: "invalid_json", reason: REASONS.notUtf8 };
  }

  // Parse with a source-aware reviver: JSON.parse alone silently rounds
  // integer literals beyond ±(2^53-1) to the nearest double (e.g.
  // 9007199254740993 -> 9007199254740992), so Number.isSafeInteger on the
  // parsed value can never fire. The reviver's third argument (node >= 21)
  // exposes the raw token text, letting us compare the literal's exact value.
  let numberProblem: string | null = null;
  const reviver = (_key: string, value: unknown, context?: { source?: string }) => {
    if (typeof value === "number" && numberProblem === null) {
      if (!Number.isFinite(value)) {
        // e.g. 1e999 parses to Infinity in JS; other runtimes may reject the
        // token at decode time instead — same code+reason either way.
        numberProblem = REASONS.nonFiniteNumber;
      } else if (context?.source !== undefined && /^-?\d+$/.test(context.source)) {
        // Integer literal (no fraction/exponent): its exact value must fit
        // in the I-JSON safe range. Exponent forms like 1e30 denote doubles
        // and canonicalize deterministically, so they are not checked here.
        const exact = BigInt(context.source);
        if (exact > 9007199254740991n || exact < -9007199254740991n) {
          numberProblem = REASONS.unsafeInteger;
        }
      }
    }
    return value;
  };

  let parsed: unknown;
  try {
    // Cast: tsconfig lib ES2022 types the reviver as 2-arg; the runtime
    // (node 24) passes the 3rd source-context argument.
    parsed = JSON.parse(
      text,
      reviver as (this: unknown, key: string, value: unknown) => unknown,
    );
  } catch {
    return { ok: false, code: "invalid_json", reason: REASONS.notJson };
  }
  if (numberProblem !== null) {
    return invalid(numberProblem);
  }

  if (!isPlainObject(parsed)) {
    return invalid(REASONS.entryNotObject);
  }
  const entry = parsed;

  for (const field of REQUIRED_FIELDS) {
    if (!Object.hasOwn(entry, field)) {
      return invalid(REASONS.missingField(field));
    }
  }
  for (const key of Object.keys(entry)) {
    if (!(REQUIRED_FIELDS as readonly string[]).includes(key)) {
      return invalid(REASONS.extraTopLevelField);
    }
  }

  if (entry["version"] !== 1) {
    return invalid(REASONS.wrongVersion);
  }

  for (const field of ["log_id", "entry_id", "writer_id"] as const) {
    const problem = uuidProblem(entry[field]);
    if (problem !== null) {
      return invalid(problem);
    }
  }

  const writerSeq = entry["writer_seq"];
  if (typeof writerSeq !== "number") {
    return invalid(REASONS.writerSeqNotNumber);
  }
  if (!Number.isInteger(writerSeq)) {
    return invalid(REASONS.writerSeqNotInteger);
  }
  if (writerSeq < 1) {
    return invalid(REASONS.writerSeqNotPositive);
  }

  const prevEntryId = entry["prev_entry_id"];
  if (writerSeq === 1) {
    if (prevEntryId !== null) {
      return invalid(REASONS.prevEntryIdNotNullAtSeq1);
    }
  } else {
    if (prevEntryId === null) {
      return invalid(REASONS.prevEntryIdNullAfterSeq1);
    }
    const problem = uuidProblem(prevEntryId);
    if (problem !== null) {
      return invalid(problem);
    }
  }

  const createdAt = entry["created_at"];
  if (typeof createdAt !== "string") {
    return invalid(REASONS.createdAtNotString);
  }
  if (!RFC3339_UTC_RE.test(createdAt)) {
    return invalid(
      RFC3339_OFFSET_RE.test(createdAt)
        ? REASONS.createdAtNotUtc
        : REASONS.createdAtNotRfc3339,
    );
  }
  if (Number.isNaN(Date.parse(createdAt))) {
    return invalid(REASONS.createdAtNotRfc3339);
  }

  const body = entry["body"];
  if (!isPlainObject(body)) {
    return invalid(REASONS.bodyNotObject);
  }
  const unicodeProblem = findIllFormedString(body);
  if (unicodeProblem !== null) {
    return invalid(unicodeProblem);
  }

  const canonicalBytes = canonicalize(entry);
  if (canonicalBytes.byteLength > MAX_CANONICAL_BYTES) {
    return {
      ok: false,
      code: "entry_too_large",
      reason: REASONS.canonicalBytesOver1MiB,
    };
  }
  return { ok: true, canonicalBytes };
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function uuidProblem(value: unknown): string | null {
  if (typeof value !== "string") {
    return REASONS.uuidNotString;
  }
  if (UUID_RE.test(value)) {
    return null;
  }
  return UUID_RE.test(value.toLowerCase())
    ? REASONS.uuidNotLowercase
    : REASONS.uuidMalformed;
}

/**
 * I-JSON: strings are valid Unicode. JSON syntax admits lone surrogate
 * escapes ("\ud800"), which JSON.parse passes through as ill-formed UTF-16.
 * Checks every string — keys and values — reachable from `value`.
 */
function findIllFormedString(value: unknown): string | null {
  if (typeof value === "string") {
    return isWellFormedUtf16(value) ? null : REASONS.illFormedUnicode;
  }
  if (Array.isArray(value)) {
    for (const element of value) {
      const problem = findIllFormedString(element);
      if (problem !== null) return problem;
    }
    return null;
  }
  if (isPlainObject(value)) {
    for (const [key, element] of Object.entries(value)) {
      if (!isWellFormedUtf16(key)) return REASONS.illFormedUnicode;
      const problem = findIllFormedString(element);
      if (problem !== null) return problem;
    }
  }
  return null;
}

/** ES2022-compatible stand-in for String.prototype.isWellFormed (ES2024). */
function isWellFormedUtf16(s: string): boolean {
  // for..of iterates code points; a lone surrogate surfaces as a
  // single-unit "code point" in the surrogate range.
  for (const ch of s) {
    const cp = ch.codePointAt(0) as number;
    if (cp >= 0xd800 && cp <= 0xdfff) {
      return false;
    }
  }
  return true;
}
