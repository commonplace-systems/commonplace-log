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
  createdAtLeapSecond: "created-at-leap-second",
  bodyNotObject: "body-not-object",
  unsafeInteger: "unsafe-integer",
  nonFiniteNumber: "non-finite-number",
  illFormedUnicode: "ill-formed-unicode",
  canonicalBytesOver1MiB: "canonical-bytes-over-1mib",
} as const;

const MAX_CANONICAL_BYTES = 1_048_576; // 1 MiB, spec §7.1

// HARD CONSTRAINT: unsafe-integer detection (conformance case
// 022-unsafe-integer-in-body) requires JSON.parse to pass the reviver's
// third source-context argument (node >= 21 / modern V8). On a runtime that
// does not, the check silently never fires — and the deployed Durable Object
// never runs the test suite, so silent weakening must instead be a loud
// startup failure. Probe at module load and refuse to load without it.
{
  let sourceSeen = false;
  JSON.parse(
    "0",
    ((_key: string, value: unknown, context?: { source?: string }) => {
      if (context?.source === "0") {
        sourceSeen = true;
      }
      return value;
    }) as (this: unknown, key: string, value: unknown) => unknown,
  );
  if (!sourceSeen) {
    throw new Error(
      "entry validation unavailable: this JavaScript runtime's JSON.parse " +
        "does not pass the reviver source context (context.source), so raw " +
        "integer-literal validation (I-JSON safe-integer rule, conformance " +
        "case 022) cannot run. Refusing to load with silently weakened " +
        "validation; a runtime with JSON.parse source access (node >= 21 " +
        "or an equivalent V8) is required.",
    );
  }
}

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
  /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?Z$/;
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

  // Value-based like writer_seq (case 018): 1.0 === 1 passes; anything else
  // — 2, "1", non-numbers — is wrong-version.
  if (entry["version"] !== 1) {
    return invalid(REASONS.wrongVersion);
  }

  for (const field of ["log_id", "entry_id", "writer_id"] as const) {
    const problem = uuidProblem(entry[field]);
    if (problem !== null) {
      return invalid(problem);
    }
  }

  // Integer-field semantics are VALUE-based (conformance cases 018 and 030):
  // the JSON spelling is irrelevant — 27.0 and 27 are the same double, and
  // canonicalize() emits identical bytes for either — but the VALUE must be
  // a safe integer (integral, |v| <= 2^53-1). Number.isSafeInteger rejects
  // both fractional values (1.5) and integral doubles beyond the safe range
  // (1e30), which plain Number.isInteger would accept. This is deliberately
  // different from the body big-int rule (case 022), which is lexical: a
  // plain integer literal losing precision at parse is a different hazard.
  const writerSeq = entry["writer_seq"];
  if (typeof writerSeq !== "number") {
    return invalid(REASONS.writerSeqNotNumber);
  }
  if (!Number.isSafeInteger(writerSeq)) {
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
  const createdAtProblem = timestampProblem(createdAt);
  if (createdAtProblem !== null) {
    return invalid(createdAtProblem);
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

/**
 * Validates a `created_at` value against the corpus-pinned rules: RFC 3339
 * date-time restricted to the Z form, with real calendar arithmetic —
 * deliberately NOT Date.parse, whose ECMAScript semantics roll invalid days
 * over (2026-02-30 -> Mar 2) instead of rejecting them. Leap seconds (:60),
 * which RFC 3339 itself permits, are rejected by corpus policy with their own
 * slug: date libraries disagree wildly on them across runtimes, and the
 * corpus wants one spelling per instant.
 */
function timestampProblem(value: string): string | null {
  const match = RFC3339_UTC_RE.exec(value);
  if (match === null) {
    return RFC3339_OFFSET_RE.test(value)
      ? REASONS.createdAtNotUtc
      : REASONS.createdAtNotRfc3339;
  }
  const [, year, month, day, hour, minute, second] = match as unknown as [
    string, string, string, string, string, string, string,
  ];
  const y = Number(year);
  const m = Number(month);
  const d = Number(day);
  if (m < 1 || m > 12 || d < 1 || d > daysInMonth(y, m)) {
    return REASONS.createdAtNotRfc3339;
  }
  if (Number(hour) > 23 || Number(minute) > 59) {
    return REASONS.createdAtNotRfc3339;
  }
  const s = Number(second);
  if (s === 60) {
    return REASONS.createdAtLeapSecond;
  }
  if (s > 60) {
    return REASONS.createdAtNotRfc3339;
  }
  return null;
}

function daysInMonth(year: number, month: number): number {
  // month is 1-based and already range-checked by the caller.
  const lengths = [31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31] as const;
  if (month === 2 && isLeapYear(year)) {
    return 29;
  }
  return lengths[month - 1] as number;
}

function isLeapYear(year: number): boolean {
  return (year % 4 === 0 && year % 100 !== 0) || year % 400 === 0;
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
