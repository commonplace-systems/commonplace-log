/**
 * The §11.6 error surface: the ONE place every wire error code and its HTTP
 * status are spelled (grep-provable single spelling site), the envelope
 * constructor, and the StoreError-details -> wire-details key mapper.
 *
 * Runtime-neutral pure module (no Request/Response, no I/O): unit-tested in
 * the plain-node project like merge-plan, consumed by http.ts in workerd.
 */

/**
 * The FULL §11.6 status/code table — including rows this Durable Object
 * never emits itself:
 *
 * - `unauthenticated` (401) and `unauthorized` (403) are enforced by the
 *   public gateway (SP4); raw Durable Objects are never public (§11), so no
 *   DO code path constructs them.
 * - `storage_full` (507, §15.6) is emitted when SQLite reports exhaustion —
 *   not simulable in local workerd, so the row is pinned here by a unit test
 *   rather than an end-to-end test.
 */
export const ERROR_STATUS = {
  invalid_json: 400,
  unauthenticated: 401,
  unauthorized: 403,
  log_not_found: 404,
  log_mismatch: 409,
  writer_gap: 409,
  writer_fork: 409,
  entry_id_collision: 409,
  entry_too_large: 413,
  batch_too_large: 413,
  invalid_entry: 422,
  storage_full: 507,
} as const;

export type ErrorCode = keyof typeof ERROR_STATUS;

export interface ErrorEnvelope {
  error: {
    code: ErrorCode;
    message: string;
    details?: unknown;
  };
}

/** Build the §11.6 envelope; the details key is absent, not null, when unused. */
export function envelope(
  code: ErrorCode,
  message: string,
  details?: unknown,
): ErrorEnvelope {
  return details === undefined
    ? { error: { code, message } }
    : { error: { code, message, details } };
}

/**
 * Map StoreError camelCase detail keys to §11.6 snake_case wire fields
 * (`expectedSeq` -> `expected_seq`, `tipEntryId` -> `tip_entry_id`,
 * `writerId` -> `writer_id`, `entryId` -> `entry_id`, and any other
 * camelCase key by the same rule). Keys already lower-case pass through
 * unchanged; non-object details pass through whole. Never mutates its input.
 */
export function toWireDetails(details: unknown): unknown {
  if (details === null || typeof details !== "object" || Array.isArray(details)) {
    return details;
  }
  const wire: Record<string, unknown> = {};
  for (const [key, value] of Object.entries(details)) {
    wire[key.replace(/([a-z0-9])([A-Z])/g, "$1_$2").toLowerCase()] = value;
  }
  return wire;
}
