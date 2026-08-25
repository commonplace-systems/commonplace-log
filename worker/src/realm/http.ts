import {
  RealmStore,
  RealmStoreError,
  type CommitPlan,
  type EntryRow,
  type ReadQuery,
  type TipRow,
} from "./store";

type JsonRecord = Record<string, unknown>;

class MalformedRequest extends Error {
  constructor() {
    super("malformed_request");
    this.name = "MalformedRequest";
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
  try {
    return object(await request.json());
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

function readQuery(value: JsonRecord): { logId: string; query: ReadQuery } {
  const { log_id, writers, coordinates, entry_ids } = value;
  return {
    logId: string(log_id),
    query: {
      writers: array(writers).map(string),
      coordinates: array(coordinates).map((coordinate) => {
        const row = object(coordinate);
        const { writer_id, writer_seq } = row;
        return { writerId: string(writer_id), writerSeq: integer(writer_seq) };
      }),
      entryIds: array(entry_ids).map(string),
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
  }
}

export async function handleRealmRequest(request: Request, store: RealmStore): Promise<Response> {
  try {
    const path = new URL(request.url).pathname;
    const value = await body(request);

    if (path === "/create-log") {
      const { log_id, format_version, created_at } = value;
      store.createLog(string(log_id), {
        formatVersion: optionalInteger(format_version),
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
        limit: positiveInteger(limit),
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
        limit: positiveInteger(limit),
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
    if (error instanceof RealmStoreError) return storageError(error);
    throw error;
  }
}
