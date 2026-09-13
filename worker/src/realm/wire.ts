import { validateEntry } from "../entry";
import { handleRealmRequest } from "./http";
import { RealmStore, RealmStoreError, type EntryRow, type RestoreBundle } from "./store";

const MAX_RAW_BODY_BYTES = 32 * 1024 * 1024;
const MAX_LOGS = 64;
const MAX_ENTRIES_PER_LOG = 4096;
const MAX_ENTRY_BYTES = 1_048_576;
const MAX_TOTAL_BYTES = 16 * 1024 * 1024;
const MAX_ID_BYTES = 256;
const MAX_INVENTORY_RESPONSE_BYTES = 256 * 1024;
const UTF8 = new TextEncoder();

class WireMalformed extends Error {}
class WireOversize extends Error {}

function response(body: unknown, status: number): Response {
  return Response.json(body, { status });
}

function failure(code: string, status: number): Response {
  return response({ ok: false, error: { code } }, status);
}

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new WireMalformed();
  return value as Record<string, unknown>;
}

function strictKeys(value: Record<string, unknown>, allowed: readonly string[]): void {
  const set = new Set(allowed);
  if (Object.keys(value).some((key) => !set.has(key))) throw new WireMalformed();
}

function boundedString(value: unknown): string {
  if (typeof value !== "string" || value.length === 0 || UTF8.encode(value).byteLength > MAX_ID_BYTES) {
    throw new WireMalformed();
  }
  return value;
}

function boundedInteger(value: unknown, max: number): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1 || value > max) {
    throw new WireMalformed();
  }
  return value;
}

function encodeBase64(value: Uint8Array): string {
  let binary = "";
  const chunkSize = 16_384;
  for (let offset = 0; offset < value.byteLength; offset += chunkSize) {
    binary += String.fromCharCode(...value.subarray(offset, offset + chunkSize));
  }
  return btoa(binary);
}

function decodeCanonical(value: unknown): Uint8Array {
  if (typeof value !== "string") throw new WireMalformed();
  if (value.length > Math.ceil(MAX_ENTRY_BYTES / 3) * 4) throw new WireOversize();
  if (value.length % 4 !== 0) throw new WireMalformed();
  if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(value)) {
    throw new WireMalformed();
  }
  let decoded: Uint8Array;
  try {
    decoded = Uint8Array.from(atob(value), (character) => character.charCodeAt(0));
  } catch {
    throw new WireMalformed();
  }
  if (decoded.byteLength > MAX_ENTRY_BYTES) throw new WireOversize();
  if (encodeBase64(decoded) !== value) throw new WireMalformed();
  const checked = validateEntry(decoded);
  if (!checked.ok || checked.canonicalBytes.byteLength !== decoded.byteLength ||
      checked.canonicalBytes.some((byte, index) => byte !== decoded[index])) {
    if (!checked.ok && checked.code === "entry_too_large") throw new WireOversize();
    throw new WireMalformed();
  }
  return decoded;
}

function entryFromCanonical(canonicalBytes: Uint8Array): EntryRow {
  let parsed: Record<string, unknown>;
  try {
    parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(canonicalBytes)) as Record<string, unknown>;
  } catch {
    throw new WireMalformed();
  }
  return {
    entryId: parsed.entry_id as string,
    writerId: parsed.writer_id as string,
    writerSeq: parsed.writer_seq as number,
    prevEntryId: parsed.prev_entry_id as string | null,
    createdAt: parsed.created_at as string,
    canonicalBytes,
  };
}

interface ParsedBundle {
  bundle: RestoreBundle;
  maxLogs: number;
}

function parseBundle(value: unknown): ParsedBundle {
  const root = object(value);
  strictKeys(root, ["bundle_id", "max_logs", "logs"]);
  const bundleId = boundedString(root.bundle_id);
  const maxLogs = boundedInteger(root.max_logs, MAX_LOGS);
  if (!Array.isArray(root.logs)) throw new WireMalformed();
  if (root.logs.length === 0 || root.logs.length > MAX_LOGS) throw new WireOversize();
  let totalBytes = 0;
  const logs = root.logs.map((value) => {
    const row = object(value);
    strictKeys(row, ["log_id", "archive_id", "writer_id", "entries"]);
    const logId = boundedString(row.log_id);
    const archiveId = boundedString(row.archive_id);
    const writerId = boundedString(row.writer_id);
    if (!Array.isArray(row.entries)) throw new WireMalformed();
    if (row.entries.length > MAX_ENTRIES_PER_LOG) throw new WireOversize();
    const entries = row.entries.map((encoded) => {
      const canonicalBytes = decodeCanonical(encoded);
      totalBytes += canonicalBytes.byteLength;
      if (totalBytes > MAX_TOTAL_BYTES) throw new WireOversize();
      return entryFromCanonical(canonicalBytes);
    });
    return { logId, archiveId, writerId, entries };
  });
  return { bundle: { bundleId, logs }, maxLogs };
}

async function parseInventoryRequest(request: Request): Promise<number> {
  if (request.method !== "POST") throw new WireMalformed();
  const raw = await readRawBody(request);
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw));
  } catch {
    throw new WireMalformed();
  }
  const root = object(value);
  strictKeys(root, ["max_logs"]);
  return boundedInteger(root.max_logs, MAX_LOGS);
}

async function readRawBody(request: Request): Promise<Uint8Array> {
  if (request.body === null) throw new WireMalformed();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > MAX_RAW_BODY_BYTES) {
        try { await reader.cancel(); } catch { /* preserve the closed oversize result */ }
        throw new WireOversize();
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return body;
}

async function parseRequest(request: Request): Promise<ParsedBundle> {
  if (request.method !== "POST") throw new WireMalformed();
  const raw = await readRawBody(request);
  let value: unknown;
  try {
    value = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(raw));
  } catch {
    throw new WireMalformed();
  }
  return parseBundle(value);
}

function storeFailure(error: RealmStoreError): Response {
  if (error.code === "storage_full") return failure("storage_full", 507);
  if (error.code === "inventory_oversize") return failure("oversize", 413);
  if (error.code === "obsolete_epoch") return failure("obsolete_epoch", 409);
  return failure("constraint", 409);
}

/** Internal storage wire adapter. Public realm dispatch never calls this function. */
export async function handleStorageRequest(request: Request, store: RealmStore): Promise<Response> {
  const path = new URL(request.url).pathname;
  if (path === "/list-logs") {
    try {
      const maxLogs = await parseInventoryRequest(request);
      const result = store.listLogInventory(maxLogs);
      const payload = {
        ok: true,
        result: {
          generation: result.generation,
          logs: result.logs.map((log) => ({
            log_id: log.logId,
            format_version: log.formatVersion,
            revision: log.revision,
            created_at: log.createdAt,
            document_writer_id: log.documentWriterId,
            writers: log.writers.map((writer) => ({
              writer_id: writer.writerId,
              last_seq: writer.lastSeq,
              last_entry_id: writer.lastEntryId,
            })),
          })),
        },
      };
      if (UTF8.encode(JSON.stringify(payload)).byteLength > MAX_INVENTORY_RESPONSE_BYTES) {
        return failure("oversize", 413);
      }
      return response(payload, 200);
    } catch (error) {
      if (error instanceof WireOversize) return failure("oversize", 413);
      if (error instanceof WireMalformed) return failure("malformed", 400);
      if (error instanceof RealmStoreError) return storeFailure(error);
      return failure("internal", 500);
    }
  }
  if (path !== "/restore-bundle-batch") return await handleRealmRequest(request, store);
  try {
    const { bundle, maxLogs } = await parseRequest(request);
    const result = store.restoreBundleBatch(bundle, maxLogs);
    return response({
      ok: true,
      result: {
        imported_logs: result.importedLogs,
        skipped_logs: result.skippedLogs,
        complete: result.complete,
      },
    }, 200);
  } catch (error) {
    if (error instanceof WireOversize) return failure("oversize", 413);
    if (error instanceof WireMalformed) return failure("malformed", 400);
    if (error instanceof RealmStoreError) return storeFailure(error);
    return failure("internal", 500);
  }
}
