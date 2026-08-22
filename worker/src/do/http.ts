/**
 * The §11 HTTP protocol surface: URL routing, size gates, request parsing,
 * response serialization, and §11.6 error mapping over a LogStore. The DO
 * class (commonplace-log-do.ts) is a thin shell calling handleRequest; all
 * protocol decisions live here, all storage decisions live in store.ts.
 *
 * Routes (§11.1–§11.5, plus one internal debug route):
 *   PUT  /v1/logs/{log_id}                               create (§11.1)
 *   POST /v1/logs/{log_id}/entries                       merge  (§11.2)
 *   GET  /v1/logs/{log_id}/frontier                      §11.3
 *   GET  /v1/logs/{log_id}/writers/{writer_id}/entries   §11.4
 *   GET  /v1/logs/{log_id}/entries                       §11.5 arrival tail
 *   GET  /v1/logs/{log_id}/stats                         internal debug only
 *
 * Recorded routing decision: an unknown path or unsupported method returns
 * 404 with code `log_not_found` and message "unknown route" — §11.6 has no
 * route-not-found row, `log_not_found` is the closest spec code, and SP4's
 * gateway shields this internal surface from confusable callers.
 *
 * Recorded layering decisions (plan Task 7): the HTTP layer owns the §11.2
 * batch limits (`batch_too_large`); StoreError camelCase details map to
 * §11.6 snake_case wire fields via errors.toWireDetails; the merge-plan
 * internal `invalid_batch` already surfaces from the store as
 * `invalid_entry` (422).
 */
import { canonicalize } from "../jcs";
import {
  ERROR_STATUS,
  envelope,
  toWireDetails,
  type ErrorCode,
} from "./errors";
import { LogStore, StoreError, type FrontierEntry } from "./store";

/** §11.2 default batch limits. */
const MAX_BATCH_ENTRIES = 100;
const MAX_BATCH_CANONICAL_BYTES = 4 * 1024 * 1024; // 4 MiB

/**
 * §16 pre-parse guard: reject oversized request bodies from the
 * Content-Length header BEFORE reading or parsing anything. 4.5 MiB leaves
 * headroom over the 4 MiB canonical batch limit for JSON framing and
 * whitespace; the EXACT limit is the canonical-bytes measure taken after
 * validation below (canonical size cannot be known pre-parse). A single
 * 1 MiB entry (§11.2 MUST) passes this gate with room to spare.
 */
const MAX_RAW_BODY_BYTES = 4_718_592; // 4.5 MiB

export interface HttpDeps {
  store: LogStore;
  /** ctx.id.name — undefined when the object was not addressed by name. */
  objectName: string | undefined;
}

/** A protocol-layer error carrying its own wire message and details. */
class HttpError extends Error {
  constructor(
    readonly code: ErrorCode,
    message: string,
    readonly details?: unknown,
  ) {
    super(message);
    this.name = "HttpError";
  }
}

export async function handleRequest(
  req: Request,
  deps: HttpDeps,
): Promise<Response> {
  try {
    return await route(req, deps);
  } catch (error) {
    if (error instanceof HttpError) {
      return errorResponse(error.code, error.message, error.details);
    }
    if (error instanceof StoreError) {
      return errorResponse(
        error.code,
        storeErrorMessage(error),
        toWireDetails(error.details),
      );
    }
    if (error instanceof RangeError) {
      // Store read-argument contract violations (§9.5/§9.6 params).
      return errorResponse("invalid_entry", error.message, {
        reason: error.message,
      });
    }
    if (
      error instanceof Error &&
      /SQLITE_FULL|database or disk is full/i.test(error.message)
    ) {
      // §15.6: storage exhaustion — the transaction already rolled back.
      return errorResponse("storage_full", "store cannot durably accept more entries", {
        reason: error.message,
      });
    }
    throw error;
  }
}

async function route(req: Request, deps: HttpDeps): Promise<Response> {
  const url = new URL(req.url);
  const seg = url.pathname.split("/").filter((s) => s !== "");

  if (seg.length < 3 || seg[0] !== "v1" || seg[1] !== "logs") {
    throw unknownRoute();
  }
  const logId = decodeURIComponent(seg[2]!);

  // §13.1: every /v1/logs/{log_id}/... request verifies the Durable Object's
  // name against the path's log_id, so a routing bug cannot silently reuse a
  // database for another logical log. SP2 accepts a bare log_id as the
  // object name; scope prefixing (`<scope_id>:<log_id>`) is SP4's concern.
  if (deps.objectName === undefined) {
    // Reached via idFromString()/newUniqueId(): there is no name to verify.
    // Explicit rejection — never an accidental `undefined !== logId` result.
    throw new HttpError(
      "log_mismatch",
      "durable object identity is unverifiable",
      {
        reason:
          `this durable object has no name (it was addressed by unique id, ` +
          `not idFromName), so it cannot be verified to store log ${logId}`,
      },
    );
  }
  if (deps.objectName !== logId) {
    throw new HttpError(
      "log_mismatch",
      "durable object name does not match the requested log_id",
      { object_name: deps.objectName, log_id: logId },
    );
  }

  const { store } = deps;
  if (seg.length === 3) {
    if (req.method === "PUT") return await handleCreate(req, store, logId);
    throw unknownRoute();
  }
  if (seg.length === 4 && seg[3] === "entries") {
    if (req.method === "POST") return await handleMerge(req, store);
    if (req.method === "GET") return handleTail(url, store);
    throw unknownRoute();
  }
  if (seg.length === 4 && seg[3] === "frontier" && req.method === "GET") {
    return handleFrontier(store, logId);
  }
  if (seg.length === 4 && seg[3] === "stats" && req.method === "GET") {
    return handleStats(store);
  }
  if (
    seg.length === 6 &&
    seg[3] === "writers" &&
    seg[5] === "entries" &&
    req.method === "GET"
  ) {
    return handleReadWriter(url, store, decodeURIComponent(seg[4]!));
  }
  throw unknownRoute();
}

/** §11.1: PUT create — 200 whether the log was created or already existed. */
async function handleCreate(
  req: Request,
  store: LogStore,
  logId: string,
): Promise<Response> {
  const body = await readJsonBody(req);
  // The spec's request body is exactly {"version":1}; any other version is a
  // request this implementation cannot honor. §11.6 has no dedicated code
  // for a malformed create request — invalid_entry (422, "violates the
  // version 1 format") is the closest row. Recorded decision.
  if (!isPlainObject(body) || body["version"] !== 1) {
    throw new HttpError("invalid_entry", "create request must be {\"version\":1}", {
      reason: "create-body-version-must-be-1",
    });
  }
  store.createLog(logId);
  return json(200, { ok: true });
}

/** §11.2: POST merge — batch limits here, merge semantics in the store. */
async function handleMerge(req: Request, store: LogStore): Promise<Response> {
  const body = await readJsonBody(req);
  if (!isPlainObject(body) || !Array.isArray(body["entries"])) {
    throw new HttpError("invalid_entry", "request body must be {\"entries\":[...]}", {
      reason: "request-body-not-an-entries-batch",
    });
  }
  const entries = body["entries"] as unknown[];

  if (entries.length > MAX_BATCH_ENTRIES) {
    throw new HttpError("batch_too_large", "too many entries in one batch", {
      entry_count: entries.length,
      max_entries: MAX_BATCH_ENTRIES,
    });
  }

  // The EXACT §11.2 measure: total canonical entry bytes. Canonicalization
  // needs parsed values, hence this runs after the §16 raw gate and JSON
  // parse. An entry that fails to canonicalize is left for the store's
  // validator to reject with its proper invalid_entry reason.
  let canonicalTotal = 0;
  let measurable = true;
  for (const entry of entries) {
    try {
      canonicalTotal += canonicalize(entry).byteLength;
    } catch {
      measurable = false;
      break;
    }
  }
  if (measurable && canonicalTotal > MAX_BATCH_CANONICAL_BYTES) {
    throw new HttpError("batch_too_large", "batch exceeds the canonical byte limit", {
      canonical_bytes: canonicalTotal,
      max_canonical_bytes: MAX_BATCH_CANONICAL_BYTES,
    });
  }

  const result = store.mergeEntries(entries);
  return json(200, {
    inserted: result.inserted,
    present: result.present,
    frontier: { writers: result.frontier.map(wireWriter) },
  });
}

/** §11.3: GET frontier in the §9.4 encoded shape. */
function handleFrontier(store: LogStore, logId: string): Response {
  return json(200, { log_id: logId, writers: store.frontier().map(wireWriter) });
}

/** §11.4: GET one writer's canonical entries with paging. */
function handleReadWriter(
  url: URL,
  store: LogStore,
  writerId: string,
): Response {
  const after = intParam(url, "after", 0);
  const through = intParam(url, "through", null);
  const limit = clampLimit(intParam(url, "limit", 100));
  const result = store.readWriter(writerId, after, through, limit);
  return json(200, {
    entries: result.entries.map((e) => parseCanonical(e.canonicalBytes)),
    next_after: result.nextAfterSeq,
  });
}

/** §11.5: GET the replica-local arrival tail (never for synchronization). */
function handleTail(url: URL, store: LogStore): Response {
  const afterArrival = intParam(url, "after_arrival", 0);
  const limit = clampLimit(intParam(url, "limit", 100));
  const result = store.tailLocal(afterArrival, limit);
  return json(200, {
    entries: result.entries.map((e) => parseCanonical(e.canonicalBytes)),
    next_after_arrival: result.nextAfterArrival,
  });
}

/**
 * INTERNAL DEBUG ROUTE (§17 observability, counts only — bodies are never
 * exposed here). Not part of the §11 protocol; SP4's gateway must not
 * forward it to tenants. Counts derive from the frontier alone: §8
 * invariant 5 (every stored writer sequence is a complete prefix from 1)
 * makes Σ tip.seq EXACTLY the stored entry count, so no store change or
 * extra SQL is needed.
 */
function handleStats(store: LogStore): Response {
  const frontier = store.frontier();
  const entries = frontier.reduce((sum, w) => sum + w.seq, 0);
  return json(200, { entries, writers: frontier.length });
}

// ---------------------------------------------------------------------------
// Request/response plumbing

/**
 * Read and parse a JSON request body, enforcing the §16 pre-parse size gate:
 * the Content-Length header is checked BEFORE the body is read, and the
 * decoded byte count is re-checked after (covers chunked bodies with no
 * Content-Length). Malformed JSON -> 400 invalid_json.
 */
async function readJsonBody(req: Request): Promise<unknown> {
  const contentLength = req.headers.get("content-length");
  if (contentLength !== null && Number(contentLength) > MAX_RAW_BODY_BYTES) {
    throw rawBodyTooLarge(Number(contentLength));
  }
  const text = await req.text();
  const rawBytes = new TextEncoder().encode(text).byteLength;
  if (rawBytes > MAX_RAW_BODY_BYTES) {
    throw rawBodyTooLarge(rawBytes);
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new HttpError("invalid_json", "request is not valid JSON");
  }
}

function rawBodyTooLarge(rawBytes: number): HttpError {
  return new HttpError("batch_too_large", "request body exceeds the raw size limit", {
    raw_bytes: rawBytes,
    max_raw_bytes: MAX_RAW_BODY_BYTES,
  });
}

function unknownRoute(): HttpError {
  // Recorded decision (see module comment): 404 log_not_found for unknown
  // paths and methods — §11.6's closest code; SP4 shields this surface.
  return new HttpError("log_not_found", "unknown route");
}

/**
 * Strict integer query parameter: absent -> fallback; anything but an
 * optionally-signed decimal integer -> 422 invalid_entry. Range rules
 * (non-negative, positive limit) are the store's RangeError contract, mapped
 * in handleRequest.
 */
function intParam<F extends number | null>(
  url: URL,
  name: string,
  fallback: F,
): number | F {
  const raw = url.searchParams.get(name);
  if (raw === null || raw === "") return fallback;
  if (!/^-?\d+$/.test(raw)) {
    throw new HttpError(
      "invalid_entry",
      `query parameter ${name} must be an integer`,
      { reason: `query parameter ${name} must be an integer, got ${JSON.stringify(raw)}` },
    );
  }
  return Number(raw);
}

/** Default page limit 100, hard cap 1000 (values above the cap clamp). */
function clampLimit(limit: number): number {
  return Math.min(limit, 1000);
}

function wireWriter(tip: FrontierEntry): {
  writer_id: string;
  seq: number;
  entry_id: string;
} {
  return { writer_id: tip.writerId, seq: tip.seq, entry_id: tip.entryId };
}

/** Stored canonical bytes ARE the wire entry: parse and re-emit as JSON. */
function parseCanonical(bytes: Uint8Array): unknown {
  return JSON.parse(new TextDecoder().decode(bytes));
}

function storeErrorMessage(error: StoreError): string {
  const details = isPlainObject(error.details) ? error.details : {};
  switch (error.code) {
    case "log_not_found":
      return "log has not been provisioned";
    case "log_mismatch":
      return "physical store belongs to another log";
    case "writer_gap":
      // Matches the §11.6 example: "expected writer sequence 28".
      return `expected writer sequence ${details["expectedSeq"]}`;
    case "writer_fork":
      return `writer coordinate (${details["writerId"]}, ${details["seq"]}) holds a different entry`;
    case "entry_id_collision":
      return `entry_id ${details["entryId"]} names different bytes`;
    case "entry_too_large":
      return "entry exceeds the 1 MiB canonical size limit";
    case "invalid_entry":
      return "entry violates the version 1 format";
  }
}

function errorResponse(
  code: ErrorCode,
  message: string,
  details?: unknown,
): Response {
  return json(ERROR_STATUS[code], envelope(code, message, details));
}

function json(status: number, value: unknown): Response {
  return new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}
