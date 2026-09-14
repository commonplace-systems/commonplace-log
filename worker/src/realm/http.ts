import {
  RealmStore,
  RealmStoreError,
  type CommitPlan,
  type EntryRow,
  type ReadQuery,
  type TipRow,
} from "./store";

type JsonRecord = Record<string, unknown>;

/**
 * LOG-REALM-HARDEN-3 size gates, mirroring the class of gates the do/ surface has
 * (do/http.ts: raw-body cap, batch caps, limit clamp at 1000).
 *
 * Raw body cap: ordinary realm traffic is engine commit/read traffic whose entries are at most
 * 1 MiB canonical each (schema.ts ENTRY_SIZE_TRIGGER enforces that on insert). The do/ surface
 * caps a batch at 4 MiB canonical bytes; this surface carries the same bytes base64-framed
 * (x4/3 ≈ 5.6 MiB), so 8 MiB covers the largest legitimate commit with headroom while staying
 * far below the 32 MiB cap the restore-only wire (wire.ts) uses at the gateway.
 */
const MAX_RAW_BODY_BYTES = 8 * 1024 * 1024;
/** Page limit clamp — same cap as do/http.ts clampLimit. Clamped, never refused: the engine's
 * document lane sends limit = tip_seq, which grows without bound, and a refusal there would be
 * an outage. */
const MAX_PAGE_LIMIT = 1000;
/**
 * /read-set arrays expand into SQL placeholders (writers and entry_ids one each, coordinates
 * two each, always alongside log_id). Workers SQLite refuses any statement with more than 100
 * bound parameters ("too many SQL variables", measured under workerd), so these are the largest
 * sets the storage can answer at all; refusing above them replaces an opaque 500 with a named
 * 413, and the engine's real queries (one writer, one coordinate/entry_id per merged entry with
 * merge pages of ~100 halved by the coordinate doubling) sit far below the bound.
 */
const MAX_READ_SET_WRITERS = 99;
const MAX_READ_SET_COORDINATES = 49;
const MAX_READ_SET_ENTRY_IDS = 99;
/** The id-size bound the restore wire (wire.ts MAX_ID_BYTES) already enforces for imported ids. */
const MAX_LOG_ID_BYTES = 256;

const UTF8 = new TextEncoder();

class MalformedRequest extends Error {
  constructor() {
    super("malformed_request");
    this.name = "MalformedRequest";
  }
}

/** A refusal that already knows its wire code and status. */
class RequestRefused extends Error {
  constructor(
    readonly code: string,
    readonly status: number,
  ) {
    super(code);
    this.name = "RequestRefused";
  }
}

function json(body: unknown, status = 200): Response {
  return Response.json(body, { status });
}

function fail(code: string, status: number): Response {
  return json({ ok: false, error: { code } }, status);
}

function object(value: unknown): JsonRecord {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new MalformedRequest();
  return value as JsonRecord;
}

function string(value: unknown): string {
  if (typeof value !== "string") throw new MalformedRequest();
  return value;
}

function nullableString(value: unknown): string | null {
  if (value === null) return null;
  return string(value);
}

function integer(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 0) {
    throw new MalformedRequest();
  }
  return value;
}

function positiveInteger(value: unknown): number {
  const result = integer(value);
  if (result === 0) throw new MalformedRequest();
  return result;
}

function optionalInteger(value: unknown): number | undefined {
  return value === undefined ? undefined : integer(value);
}

function array(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new MalformedRequest();
  return value;
}

function onlyKeys(row: JsonRecord, allowed: readonly string[]): void {
  const allowedKeys = new Set(allowed);
  if (Object.keys(row).some((key) => !allowedKeys.has(key))) throw new MalformedRequest();
}

function decodeBase64(value: unknown): Uint8Array {
  const encoded = string(value);
  if (encoded.length % 4 !== 0 || !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(encoded)) {
    throw new MalformedRequest();
  }
  try {
    return Uint8Array.from(atob(encoded), (character) => character.charCodeAt(0));
  } catch {
    throw new MalformedRequest();
  }
}

function encodeBase64(value: Uint8Array): string {
  let binary = "";
  const chunkSize = 16_384;
  for (let offset = 0; offset < value.length; offset += chunkSize) {
    binary += String.fromCharCode(...value.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

async function body(request: Request): Promise<JsonRecord> {
  if (request.method !== "POST") throw new MalformedRequest();
  if (request.body === null) throw new MalformedRequest();
  // Streamed with a running byte count (the wire.ts readRawBody shape) rather than a
  // Content-Length precheck: the cap then holds for chunked bodies and lying headers alike.
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > MAX_RAW_BODY_BYTES) {
        try { await reader.cancel(); } catch { /* preserve the oversize result */ }
        throw new RequestRefused("oversize", 413);
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const raw = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    raw.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return object(JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw)));
  } catch (error) {
    if (error instanceof MalformedRequest) throw error;
    throw new MalformedRequest();
  }
}

function entryRow(value: unknown, planLogId: string): EntryRow {
  const row = object(value);
  onlyKeys(row, [
    "log_id",
    "entry_id",
    "writer_id",
    "writer_seq",
    "prev_entry_id",
    "created_at",
    "canonical_bytes",
  ]);
  if (Object.hasOwn(row, "log_id") && string(row.log_id) !== planLogId) throw new MalformedRequest();
  // Destructure once so no incoming property can produce two different values.
  const {
    entry_id,
    writer_id,
    writer_seq,
    prev_entry_id,
    created_at,
    canonical_bytes,
  } = row;
  return {
    entryId: string(entry_id),
    writerId: string(writer_id),
    writerSeq: integer(writer_seq),
    prevEntryId: nullableString(prev_entry_id),
    createdAt: string(created_at),
    canonicalBytes: decodeBase64(canonical_bytes),
  };
}

function tipRow(value: unknown): TipRow {
  const row = object(value);
  onlyKeys(row, ["writer_id", "last_seq", "last_entry_id"]);
  const { writer_id, last_seq, last_entry_id } = row;
  return {
    writerId: string(writer_id),
    lastSeq: integer(last_seq),
    lastEntryId: string(last_entry_id),
  };
}

function commitPlan(value: JsonRecord): CommitPlan {
  const { log_id, expected_revision, expected_epoch, insert_entries, put_tips } = value;
  const logId = string(log_id);
  return {
    logId,
    expectedRevision: integer(expected_revision),
    expectedEpoch: integer(expected_epoch),
    insertEntries: array(insert_entries).map((entry) => entryRow(entry, logId)),
    putTips: array(put_tips).map(tipRow),
  };
}

function boundedArray(value: unknown, maxItems: number): unknown[] {
  const items = array(value);
  if (items.length > maxItems) throw new RequestRefused("oversize", 413);
  return items;
}

function readQuery(value: JsonRecord): { logId: string; query: ReadQuery } {
  const { log_id, writers, coordinates, entry_ids } = value;
  return {
    logId: string(log_id),
    query: {
      writers: boundedArray(writers, MAX_READ_SET_WRITERS).map(string),
      coordinates: boundedArray(coordinates, MAX_READ_SET_COORDINATES).map((coordinate) => {
        const row = object(coordinate);
        const { writer_id, writer_seq } = row;
        return { writerId: string(writer_id), writerSeq: integer(writer_seq) };
      }),
      entryIds: boundedArray(entry_ids, MAX_READ_SET_ENTRY_IDS).map(string),
    },
  };
}

function storageError(error: RealmStoreError): Response {
  switch (error.code) {
    case "not_found": return fail("not_found", 404);
    case "stale_revision": return fail("stale_revision", 409);
    case "obsolete_epoch": return fail("obsolete_epoch", 409);
    case "constraint": return fail("constraint_violation", 409);
    case "storage_full": return fail("storage_full", 507);
    case "stale_epoch": return fail("obsolete_epoch", 409);
    case "inventory_oversize": return fail("oversize", 413);
    case "inventory_invalid": return fail("constraint_violation", 409);
    case "entry_bytes_mismatch": return fail("entry_bytes_mismatch", 409);
    case "invalid_writer_seq": return fail("invalid_writer_seq", 409);
    case "tip_regression": return fail("tip_regression", 409);
  }
}

export async function handleRealmRequest(request: Request, store: RealmStore): Promise<Response> {
  try {
    const path = new URL(request.url).pathname;
    const value = await body(request);

    if (path === "/list-log-ids") {
      const after = value.after_log_id === undefined ? undefined : string(value.after_log_id);
      const limit = value.limit === undefined ? 100 : positiveInteger(value.limit);
      if (limit > 1000) throw new MalformedRequest();
      const result = store.listLogs(after, limit);
      return json({ ok: true, log_ids: result.logIds, next_after_log_id: result.nextAfterLogId });
    }

    if (path === "/create-log") {
      const { log_id, format_version, created_at } = value;
      const logId = string(log_id);
      // Validated in code, not schema DDL, so the gate also protects legacy realms whose
      // stored schema predates it. An empty log_id is unaddressable downstream (the backup
      // runner hard-stops on it, worker/backup/run.ts); the byte bound is the id bound the
      // restore wire already enforces.
      if (logId.length === 0 || UTF8.encode(logId).byteLength > MAX_LOG_ID_BYTES) {
        throw new RequestRefused("invalid_log_id", 400);
      }
      const formatVersion = optionalInteger(format_version);
      // Format version 1 is the only format this implementation writes or reads.
      if (formatVersion !== undefined && formatVersion !== 1) {
        throw new RequestRefused("unsupported_format_version", 400);
      }
      store.createLog(logId, {
        formatVersion,
        createdAt: created_at === undefined ? undefined : string(created_at),
      });
      return json({ ok: true }, 201);
    }

    if (path === "/read-set") {
      const { logId, query } = readQuery(value);
      const result = store.readSet(logId, query);
      return json({
        ok: true,
        read_set: {
          log_id: result.logId,
          format_version: result.formatVersion,
          revision: result.revision,
          lease_epoch: result.leaseEpoch,
          document_writer_id: result.documentWriterId,
          tips: result.tips.map((tip) => ({
            writer_id: tip.writerId,
            last_seq: tip.lastSeq,
            last_entry_id: tip.lastEntryId,
          })),
          coordinates: result.coordinates.map((entry) => ({
            writer_id: entry.writerId,
            writer_seq: entry.writerSeq,
            canonical_bytes: encodeBase64(entry.canonicalBytes),
          })),
          entry_ids: result.entryIds.map((entry) => ({
            entry_id: entry.entryId,
            canonical_bytes: encodeBase64(entry.canonicalBytes),
          })),
        },
      });
    }

    if (path === "/take-lease") {
      const { log_id } = value;
      const lease = store.takeLease(string(log_id));
      return json({ ok: true, lease_epoch: lease.leaseEpoch, writer_id: lease.writerId });
    }

    if (path === "/commit") {
      const revision = store.commit(commitPlan(value));
      return json({ ok: true, revision });
    }

    if (path === "/frontier") {
      const { log_id } = value;
      const result = store.frontier(string(log_id));
      return json({
        ok: true,
        frontier: {
          writers: result.writers.map((writer) => ({
            writer_id: writer.writerId,
            seq: writer.seq,
            entry_id: writer.entryId,
          })),
        },
      });
    }

    if (path === "/read-writer") {
      const { log_id, writer_id, after_seq, through_seq, limit } = value;
      const result = store.readWriter(string(log_id), string(writer_id), {
        afterSeq: integer(after_seq),
        throughSeq: optionalInteger(through_seq),
        // Clamped, never refused (see MAX_PAGE_LIMIT): callers page via next_after_seq.
        limit: Math.min(positiveInteger(limit), MAX_PAGE_LIMIT),
      });
      return json({
        ok: true,
        page: {
          entries: result.entries.map((entry) => ({
            canonical_bytes: encodeBase64(entry.canonicalBytes),
            writer_seq: entry.writerSeq,
          })),
          next_after_seq: result.nextAfterSeq,
        },
      });
    }

    if (path === "/tail-local") {
      const { log_id, after_arrival, limit } = value;
      const result = store.tailLocal(string(log_id), {
        afterArrival: integer(after_arrival),
        // Clamped, never refused (see MAX_PAGE_LIMIT): callers page via next_after_arrival.
        limit: Math.min(positiveInteger(limit), MAX_PAGE_LIMIT),
      });
      return json({
        ok: true,
        page: {
          entries: result.entries.map((entry) => ({
            canonical_bytes: encodeBase64(entry.canonicalBytes),
            arrival_seq: entry.arrivalSeq,
          })),
          next_after_arrival: result.nextAfterArrival,
        },
      });
    }

    return fail("not_found", 404);
  } catch (error) {
    if (error instanceof MalformedRequest) return fail("malformed_request", 400);
    if (error instanceof RequestRefused) return fail(error.code, error.status);
    if (error instanceof RealmStoreError) return storageError(error);
    throw error;
  }
}
