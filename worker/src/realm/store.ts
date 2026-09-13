import { initSchema } from "./schema";
import { createHash } from "node:crypto";

export type RealmStorageErrorCode =
  | "not_found"
  | "stale_epoch"
  | "stale_revision"
  | "obsolete_epoch"
  | "constraint"
  | "storage_full"
  | "inventory_oversize"
  | "inventory_invalid";

export class RealmStoreError extends Error {
  constructor(
    readonly code: RealmStorageErrorCode,
    readonly cause?: unknown,
  ) {
    super(code, cause === undefined ? undefined : { cause });
    this.name = "RealmStoreError";
  }
}

export interface EntryRow {
  entryId: string;
  writerId: string;
  writerSeq: number;
  prevEntryId: string | null;
  createdAt: string;
  canonicalBytes: Uint8Array;
}

export interface TipRow {
  writerId: string;
  lastSeq: number;
  lastEntryId: string;
}

export interface CommitPlan {
  logId: string;
  expectedRevision: number;
  expectedEpoch: number;
  insertEntries: EntryRow[];
  putTips: TipRow[];
}

export interface ReadQuery {
  writers: string[];
  coordinates: Array<{ writerId: string; writerSeq: number }>;
  entryIds: string[];
}

export interface RealmReadSet {
  logId: string;
  formatVersion: number;
  revision: number;
  leaseEpoch: number;
  documentWriterId: string | null;
  tips: TipRow[];
  coordinates: Array<{ writerId: string; writerSeq: number; canonicalBytes: Uint8Array }>;
  entryIds: Array<{ entryId: string; canonicalBytes: Uint8Array }>;
}

export interface ReadWriterOptions {
  afterSeq: number;
  throughSeq?: number;
  limit: number;
}

export interface TailLocalOptions {
  afterArrival: number;
  limit: number;
}

export interface Lease {
  leaseEpoch: number;
  writerId: string;
}

export interface RestoreArchive {
  logId: string;
  archiveId: string;
  writerId: string;
  entries: EntryRow[];
}

export interface RestoreBundle {
  bundleId: string;
  logs: RestoreArchive[];
}

export interface RestoreBundleResult {
  importedLogs: number;
  skippedLogs: number;
  complete: boolean;
}

export interface LogInventoryWriter {
  writerId: string;
  lastSeq: number;
  lastEntryId: string;
}

export interface LogInventoryRow {
  logId: string;
  formatVersion: number;
  revision: number;
  createdAt: string;
  documentWriterId: string | null;
  writers: LogInventoryWriter[];
}

export interface LogInventory {
  generation: string;
  logs: LogInventoryRow[];
}

export interface RestoreResult {
  imported: number;
  skipped: number;
  complete: boolean;
}

interface Transactor {
  transactionSync<T>(fn: () => T): T;
}

function bytes(value: unknown): Uint8Array {
  return new Uint8Array(value as ArrayBuffer);
}

const UTF8 = new TextEncoder();
const RESTORE_MARKER_PREFIX = UTF8.encode("commonplace-restore-marker-v2\0");
const RESTORE_MARKER_DIGEST_BYTES = 32;
const MAX_RESTORE_ID_BYTES = 256;
// Legacy markers are retained only while their verification input is bounded.
const MAX_LEGACY_MARKER_BYTES = 2 * 1024 * 1024;
const MAX_BUNDLE_LOGS = 64;
const BUNDLE_MARKER_PREFIX = UTF8.encode("commonplace-restore-bundle-v1\0");
const MAX_INVENTORY_LOGS = 64;
const MAX_INVENTORY_WRITERS = 4096;
const MAX_INVENTORY_BYTES = 256 * 1024;
const INVENTORY_MARKER_PREFIX = UTF8.encode("commonplace-log-inventory-v1\0");

function placeholders(values: readonly unknown[]): string {
  return values.map(() => "?").join(", ");
}

function translateStorageError(error: unknown): never {
  if (error instanceof RealmStoreError) throw error;
  const message = error instanceof Error ? error.message : String(error);
  if (message.includes("SQLITE_FULL")) throw new RealmStoreError("storage_full", error);
  if (message.includes("SQLITE_CONSTRAINT")) throw new RealmStoreError("constraint", error);
  throw error;
}

export class RealmStore {
  constructor(
    private readonly sql: SqlStorage,
    private readonly txn: Transactor,
  ) {}

  createLog(
    logId: string,
    metadata: { formatVersion?: number; createdAt?: string } = {},
  ): void {
    initSchema(this.sql);
    try {
      this.txn.transactionSync(() => {
        this.requireNoPendingRestoreBundle();
        this.sql.exec(
          `INSERT INTO logs (log_id, format_version, revision, created_at, lease_epoch)
           VALUES (?, ?, 0, ?, 0) ON CONFLICT (log_id) DO NOTHING`,
          logId,
          metadata.formatVersion ?? 1,
          metadata.createdAt ?? new Date().toISOString(),
        );
      });
    } catch (error) {
      translateStorageError(error);
    }
  }

  /** Internal provider-local restore primitive. It is intentionally not routed by HTTP. */
  restoreBatch(archive: RestoreArchive, maxEntries = 4096): RestoreResult {
    validateRestoreArchive(archive, maxEntries);
    initSchema(this.sql);
    try {
      return this.txn.transactionSync(() => {
        this.requireNoPendingRestoreBundle();
        return this.restoreArchiveInTransaction(archive, maxEntries);
      });
    } catch (error) {
      translateStorageError(error);
    }
  }

  /** Internal provider-local bundle restore primitive. It is intentionally not routed by HTTP. */
  restoreBundleBatch(bundle: RestoreBundle, maxLogs = MAX_BUNDLE_LOGS): RestoreBundleResult {
    validateRestoreBundle(bundle, maxLogs);
    if (!hasSqlTable(this.sql, "realm_meta") ||
        Number(this.sql.exec("SELECT COUNT(*) AS count FROM realm_meta").one().count) !== 1) {
      throw new RealmStoreError("constraint");
    }
    initSchema(this.sql);
    try {
      return this.txn.transactionSync(() => this.restoreBundleInTransaction(bundle, maxLogs));
    } catch (error) {
      translateStorageError(error);
    }
  }

  /** Return one bounded, deterministic snapshot of every stored application log. */
  listLogInventory(maxLogs = MAX_INVENTORY_LOGS): LogInventory {
    if (!Number.isSafeInteger(maxLogs) || maxLogs < 1 || maxLogs > MAX_INVENTORY_LOGS) {
      throw new RealmStoreError("inventory_oversize");
    }
    if (!hasSqlTable(this.sql, "realm_meta")) {
      throw new RealmStoreError("inventory_invalid");
    }
    const realmMeta = this.sql.exec(
      `SELECT singleton, length(secret_hash) AS secret_bytes,
              length(CAST(created_at AS BLOB)) AS created_at_bytes
       FROM realm_meta LIMIT 2`,
    ).toArray();
    if (realmMeta.length !== 1 || realmMeta[0] === undefined ||
        Number(realmMeta[0].singleton) !== 1 || Number(realmMeta[0].secret_bytes) !== 32 ||
        Number(realmMeta[0].created_at_bytes) > MAX_RESTORE_ID_BYTES) {
      throw new RealmStoreError("inventory_invalid");
    }

    return this.txn.transactionSync(() => {
      this.requireInventoryRestoreState();
      const hasLogs = hasSqlTable(this.sql, "logs");
      const hasEntries = hasSqlTable(this.sql, "entries");
      const hasTips = hasSqlTable(this.sql, "writer_tips");
      const hasMarkers = hasSqlTable(this.sql, "restore_markers");
      const hasBundleLogs = hasSqlTable(this.sql, "restore_bundle_logs");

      if (!hasLogs) {
        if ([hasEntries, hasTips, hasMarkers, hasBundleLogs].some(Boolean)) {
          throw new RealmStoreError("inventory_invalid");
        }
        return { generation: inventoryDigest([]), logs: [] };
      }
      if (!hasEntries || !hasTips) throw new RealmStoreError("inventory_invalid");

      const logColumns = this.sql.exec("PRAGMA table_info(logs)").toArray();
      const hasDocumentWriter = logColumns.some((column) => column.name === "document_writer_id");
      const logSummary = this.sql.exec(
        `SELECT COUNT(*) AS count,
                COALESCE(SUM(length(CAST(log_id AS BLOB)) + length(CAST(format_version AS BLOB)) +
                  length(CAST(revision AS BLOB)) + length(CAST(created_at AS BLOB)) +
                  ${hasDocumentWriter ? "length(CAST(COALESCE(document_writer_id, '') AS BLOB)) +" : ""} 64), 0) AS bytes,
                COALESCE(MAX(length(CAST(log_id AS BLOB))), 0) AS max_log_id_bytes,
                COALESCE(MAX(length(CAST(created_at AS BLOB))), 0) AS max_created_at_bytes
                ${hasDocumentWriter ? ", COALESCE(MAX(length(CAST(COALESCE(document_writer_id, '') AS BLOB))), 0) AS max_document_writer_bytes" : ""}
         FROM logs`,
      ).one();
      if (Number(logSummary.count) > maxLogs || Number(logSummary.bytes) > MAX_INVENTORY_BYTES ||
          Number(logSummary.max_log_id_bytes) > MAX_RESTORE_ID_BYTES ||
          Number(logSummary.max_created_at_bytes) > MAX_RESTORE_ID_BYTES ||
          (hasDocumentWriter && Number(logSummary.max_document_writer_bytes) > MAX_RESTORE_ID_BYTES)) {
        throw new RealmStoreError("inventory_oversize");
      }
      const logRows = this.sql.exec(
        `SELECT substr(log_id, 1, ? ) AS log_id, format_version, revision,
                substr(created_at, 1, ?) AS created_at${hasDocumentWriter ? ", substr(document_writer_id, 1, ?) AS document_writer_id" : ""}
         FROM logs ORDER BY log_id LIMIT ?`,
        ...(hasDocumentWriter ? [MAX_RESTORE_ID_BYTES + 1, MAX_RESTORE_ID_BYTES + 1, MAX_RESTORE_ID_BYTES + 1, maxLogs + 1] :
          [MAX_RESTORE_ID_BYTES + 1, MAX_RESTORE_ID_BYTES + 1, maxLogs + 1]),
      ).toArray();
      if (logRows.length > maxLogs) throw new RealmStoreError("inventory_oversize");

      const logIds = new Set<string>();
      const logs = logRows.map((row) => {
        const logId = String(row.log_id);
        const formatVersion = Number(row.format_version);
        const revision = Number(row.revision);
        const createdAt = String(row.created_at);
        const documentWriterId = hasDocumentWriter && row.document_writer_id !== null
          ? String(row.document_writer_id)
          : null;
        if (!boundedRestoreId(logId) || logIds.has(logId) ||
            !Number.isSafeInteger(formatVersion) || formatVersion < 1 ||
            !Number.isSafeInteger(revision) || revision < 0 ||
            !boundedRestoreId(createdAt) ||
            (documentWriterId !== null && !boundedRestoreId(documentWriterId))) {
          throw new RealmStoreError("inventory_invalid");
        }
        logIds.add(logId);
        return {
          logId,
          formatVersion,
          revision,
          createdAt,
          documentWriterId,
          writers: [],
        };
      });

      const writerSummary = this.sql.exec(
        `SELECT COUNT(*) AS count,
                COALESCE(SUM(length(CAST(log_id AS BLOB)) + length(CAST(writer_id AS BLOB)) +
                  length(CAST(last_entry_id AS BLOB)) + 32), 0) AS bytes,
                COALESCE(MAX(length(CAST(log_id AS BLOB))), 0) AS max_log_id_bytes,
                COALESCE(MAX(length(CAST(writer_id AS BLOB))), 0) AS max_writer_id_bytes,
                COALESCE(MAX(length(CAST(last_entry_id AS BLOB))), 0) AS max_entry_id_bytes
         FROM writer_tips`,
      ).one();
      if (Number(writerSummary.count) > MAX_INVENTORY_WRITERS ||
          Number(writerSummary.bytes) > MAX_INVENTORY_BYTES ||
          Number(writerSummary.max_log_id_bytes) > MAX_RESTORE_ID_BYTES ||
          Number(writerSummary.max_writer_id_bytes) > MAX_RESTORE_ID_BYTES ||
          Number(writerSummary.max_entry_id_bytes) > MAX_RESTORE_ID_BYTES) {
        throw new RealmStoreError("inventory_oversize");
      }

      const writersByLog = new Map<string, LogInventoryWriter[]>();
      for (const row of this.sql.exec(
        `SELECT substr(log_id, 1, ?) AS log_id, substr(writer_id, 1, ?) AS writer_id,
                last_seq, substr(last_entry_id, 1, ?) AS last_entry_id
         FROM writer_tips ORDER BY log_id, writer_id`,
        MAX_RESTORE_ID_BYTES + 1, MAX_RESTORE_ID_BYTES + 1, MAX_RESTORE_ID_BYTES + 1,
      ).toArray()) {
        const logId = String(row.log_id);
        const writerId = String(row.writer_id);
        const lastEntryId = String(row.last_entry_id);
        if (!logIds.has(logId) || !boundedRestoreId(writerId) || !boundedRestoreId(lastEntryId) ||
            !Number.isSafeInteger(Number(row.last_seq)) || Number(row.last_seq) < 1) {
          throw new RealmStoreError("inventory_invalid");
        }
        const writers = writersByLog.get(logId) ?? [];
        writers.push({ writerId, lastSeq: Number(row.last_seq), lastEntryId });
        writersByLog.set(logId, writers);
      }

      if (this.sql.exec(
        `SELECT 1 FROM entries e LEFT JOIN logs l ON l.log_id = e.log_id
         WHERE l.log_id IS NULL LIMIT 1`,
      ).toArray().length > 0 || this.sql.exec(
        `SELECT 1 FROM writer_tips w LEFT JOIN logs l ON l.log_id = w.log_id
         WHERE l.log_id IS NULL LIMIT 1`,
      ).toArray().length > 0) {
        throw new RealmStoreError("inventory_invalid");
      }

      if (hasMarkers && this.sql.exec(
        `SELECT 1 FROM restore_markers rm
         LEFT JOIN logs l ON l.log_id = rm.log_id
         WHERE l.log_id IS NULL OR rm.state <> 'complete' LIMIT 1`,
      ).toArray().length > 0) {
        throw new RealmStoreError("inventory_invalid");
      }

      const result = logs.map((log) => ({
        ...log,
        writers: writersByLog.get(log.logId) ?? [],
      }));
      const encodedSize = UTF8.encode(JSON.stringify(result)).byteLength;
      if (encodedSize > MAX_INVENTORY_BYTES) throw new RealmStoreError("inventory_oversize");
      return { generation: inventoryDigest(result), logs: result };
    });
  }

  private restoreArchiveInTransaction(archive: RestoreArchive, maxEntries: number): RestoreResult {
    const totalBytes = archive.entries.reduce((sum, entry) => sum + entry.canonicalBytes.byteLength, 0);
    const manifest = restoreManifest(archive);
    return this.restoreArchiveRowsInTransaction(archive, maxEntries, totalBytes, manifest);
  }

  private restoreArchiveRowsInTransaction(
    archive: RestoreArchive,
    maxEntries: number,
    totalBytes: number,
    manifest: Uint8Array,
  ): RestoreResult {
        const marker = this.sql.exec(
          `SELECT archive_id, writer_id, entry_count, total_bytes, manifest_json, state FROM restore_markers WHERE log_id = ?`,
          archive.logId,
        ).toArray()[0];
        const existing = this.sql.exec(
          `SELECT document_writer_id FROM logs WHERE log_id = ?`, archive.logId,
        ).toArray()[0];
        if (marker === undefined) {
          // Existing unmarked logs are never eligible for rebinding.
          if (existing !== undefined) throw new RealmStoreError("constraint");
          this.sql.exec(
            `INSERT INTO logs (log_id, format_version, revision, created_at, lease_epoch, document_writer_id)
             VALUES (?, 1, 0, ?, 0, ?)`, archive.logId, new Date().toISOString(), archive.writerId,
          );
          this.sql.exec(
            `INSERT INTO restore_markers (log_id, archive_id, writer_id, entry_count, total_bytes, manifest_json, state)
             VALUES (?, ?, ?, ?, ?, ?, 'pending')`, archive.logId, archive.archiveId, archive.writerId,
            archive.entries.length, totalBytes, manifest.buffer.slice(manifest.byteOffset, manifest.byteOffset + manifest.byteLength),
          );
        } else if (
          String(marker.archive_id) !== archive.archiveId || String(marker.writer_id) !== archive.writerId ||
          Number(marker.entry_count) !== archive.entries.length || Number(marker.total_bytes) !== totalBytes ||
          !matchesRestoreManifest(bytes(marker.manifest_json), archive, totalBytes, manifest) ||
          existing === undefined || String(existing.document_writer_id) !== archive.writerId
        ) {
          throw new RealmStoreError("constraint");
        }

        const markerState = marker === undefined ? "pending" : String(marker.state);
        if (markerState !== "pending" && markerState !== "complete") throw new RealmStoreError("constraint");

        const rows = this.sql.exec(
          `SELECT entry_id, writer_id, writer_seq, prev_entry_id, canonical_json FROM entries WHERE log_id = ? ORDER BY writer_seq`, archive.logId,
        ).toArray();
        const byId = new Map(rows.map((row) => [String(row.entry_id), bytes(row.canonical_json)]));
        const byCoordinate = new Map(rows.map((row) => [`${String(row.writer_id)}:${Number(row.writer_seq)}`, bytes(row.canonical_json)]));
        const archiveIds = new Set(archive.entries.map((entry) => entry.entryId));
        const archiveCoordinates = new Set(archive.entries.map((entry) => `${entry.writerId}:${entry.writerSeq}`));
        const archiveLastSeq = archive.entries.at(-1)?.writerSeq ?? 0;
        for (const row of rows) {
          const id = String(row.entry_id);
          const coordinate = `${String(row.writer_id)}:${Number(row.writer_seq)}`;
          if (!archiveIds.has(id) && !archiveCoordinates.has(coordinate)) {
            if (markerState !== "complete" || String(row.writer_id) !== archive.writerId ||
                Number(row.writer_seq) <= archiveLastSeq) {
              throw new RealmStoreError("constraint");
            }
          }
        }
        const targetTip = this.sql.exec(
          `SELECT writer_id, last_seq, last_entry_id FROM writer_tips WHERE log_id = ? ORDER BY writer_id`, archive.logId,
        ).toArray();
        const existingTip = targetTip[0];
        if (targetTip.length > 1 || (existingTip !== undefined && String(existingTip.writer_id) !== archive.writerId)) {
          throw new RealmStoreError("constraint");
        }
        for (let index = 0; index < rows.length; index += 1) {
          const row = rows[index];
          const previousRow = index === 0 ? undefined : rows[index - 1];
          if (row === undefined || String(row.writer_id) !== archive.writerId || Number(row.writer_seq) !== index + 1 ||
              (index === 0
                ? row.prev_entry_id !== null
                : previousRow === undefined || String(row.prev_entry_id) !== String(previousRow.entry_id))) {
            throw new RealmStoreError("constraint");
          }
        }
        if (
          (rows.length === 0 && targetTip.length !== 0) ||
          (rows.length > 0 &&
            (targetTip.length !== 1 || existingTip === undefined || Number(existingTip.last_seq) !== rows.length ||
              String(existingTip.last_entry_id) !== String(rows.at(-1)!.entry_id)))
        ) {
          throw new RealmStoreError("constraint");
        }
        if (markerState === "pending" && rows.length > archive.entries.length) throw new RealmStoreError("constraint");
        const missing: EntryRow[] = [];
        let skipped = 0;
        for (const entry of archive.entries) {
          const byIdBytes = byId.get(entry.entryId);
          const byCoordinateBytes = byCoordinate.get(`${entry.writerId}:${entry.writerSeq}`);
          if (byIdBytes !== undefined || byCoordinateBytes !== undefined) {
            if (byIdBytes === undefined || byCoordinateBytes === undefined ||
                !sameBytes(byIdBytes, entry.canonicalBytes) || !sameBytes(byCoordinateBytes, entry.canonicalBytes)) {
              throw new RealmStoreError("constraint");
            }
            skipped += 1;
          } else {
            missing.push(entry);
          }
        }
        if (markerState === "complete") {
          if (missing.length > 0) throw new RealmStoreError("constraint");
          return { imported: 0, skipped: archive.entries.length, complete: true };
        }
        const batch = missing.slice(0, maxEntries);
        for (const entry of batch) {
          this.sql.exec(
            `INSERT INTO entries (log_id, entry_id, writer_id, writer_seq, prev_entry_id, created_at, canonical_json, received_at_ms)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)`, archive.logId, entry.entryId, entry.writerId, entry.writerSeq,
            entry.prevEntryId, entry.createdAt,
            entry.canonicalBytes.buffer.slice(entry.canonicalBytes.byteOffset, entry.canonicalBytes.byteOffset + entry.canonicalBytes.byteLength),
            Date.now(),
          );
        }
        if (batch.length > 0) {
          const tip = batch.at(-1)!;
          this.sql.exec(
            `INSERT INTO writer_tips (log_id, writer_id, last_seq, last_entry_id) VALUES (?, ?, ?, ?)
             ON CONFLICT (log_id, writer_id) DO UPDATE SET last_seq = excluded.last_seq, last_entry_id = excluded.last_entry_id`,
            archive.logId, tip.writerId, tip.writerSeq, tip.entryId,
          );
          this.sql.exec(`UPDATE logs SET revision = revision + 1 WHERE log_id = ?`, archive.logId);
        }
        const complete = batch.length === missing.length;
        if (complete) this.sql.exec(`UPDATE restore_markers SET state = 'complete' WHERE log_id = ?`, archive.logId);
        return { imported: batch.length, skipped, complete };
  }

  private restoreBundleInTransaction(bundle: RestoreBundle, maxLogs: number): RestoreBundleResult {
    const digest = restoreBundleDigest(bundle);
    const storedBundle = this.sql.exec(
      `SELECT bundle_id, log_count, digest, state FROM restore_bundles WHERE singleton = 1`,
    ).toArray()[0];
    const inventoryRows = this.sql.exec(
      `SELECT bundle_id, log_id, archive_id, writer_id, entry_count, total_bytes, digest, state
       FROM restore_bundle_logs ORDER BY log_id`,
    ).toArray();
    const existingState = storedBundle === undefined ? "pending" : String(storedBundle.state);
    if (storedBundle === undefined) {
      if (inventoryRows.length > 0) throw new RealmStoreError("constraint");
      this.requireEmptyTargetForBundle();
      this.sql.exec(
        `INSERT INTO restore_bundles (singleton, bundle_id, log_count, digest, state)
         VALUES (1, ?, ?, ?, 'pending')`,
        bundle.bundleId, bundle.logs.length, digest.buffer.slice(digest.byteOffset, digest.byteOffset + digest.byteLength),
      );
      for (const archive of bundle.logs) {
        const archiveDigest = restoreManifestDigest(archive);
        this.sql.exec(
          `INSERT INTO restore_bundle_logs
           (bundle_id, log_id, archive_id, writer_id, entry_count, total_bytes, digest, state)
           VALUES (?, ?, ?, ?, ?, ?, ?, 'pending')`,
          bundle.bundleId,
          archive.logId,
          archive.archiveId,
          archive.writerId,
          archive.entries.length,
          archive.entries.reduce((sum, entry) => sum + entry.canonicalBytes.byteLength, 0),
          archiveDigest.buffer.slice(archiveDigest.byteOffset, archiveDigest.byteOffset + archiveDigest.byteLength),
        );
      }
    } else {
      this.verifyBundleRecord(storedBundle, inventoryRows, bundle, digest);
      if (String(storedBundle.state) === "pending") this.rejectUnexpectedPendingBundleRows(bundle);
    }

    const alreadyComplete = Number(this.sql.exec(
      `SELECT COUNT(*) AS count FROM restore_bundle_logs WHERE state = 'complete'`,
    ).one().count);
    const completedRows = this.sql.exec(
      `SELECT log_id FROM restore_bundle_logs WHERE state = 'complete' ORDER BY log_id`,
    ).toArray();
    const byLog = new Map(bundle.logs.map((archive) => [archive.logId, archive]));
    for (const row of completedRows) {
      const archive = byLog.get(String(row.log_id));
      const existingLog = this.sql.exec("SELECT log_id FROM logs WHERE log_id = ?", row.log_id).toArray()[0];
      const existingMarker = this.sql.exec(
        "SELECT state FROM restore_markers WHERE log_id = ?", row.log_id,
      ).toArray()[0];
      if (archive === undefined || existingLog === undefined || existingMarker === undefined ||
          String(existingMarker.state) !== "complete") {
        throw new RealmStoreError("constraint");
      }
      const verified = this.restoreArchiveInTransaction(archive, archive.entries.length);
      if (!verified.complete || verified.imported !== 0 || verified.skipped !== archive.entries.length) {
        throw new RealmStoreError("constraint");
      }
    }
    const rows = this.sql.exec(
      existingState === "complete"
        ? `SELECT log_id, state FROM restore_bundle_logs WHERE 1 = 0`
        : `SELECT log_id, state FROM restore_bundle_logs WHERE state = 'pending' ORDER BY log_id LIMIT ?`,
      ...(existingState === "complete" ? [] : [maxLogs]),
    ).toArray();
    let importedLogs = 0;
    for (const row of rows) {
      const archive = byLog.get(String(row.log_id));
      if (archive === undefined) throw new RealmStoreError("constraint");
      const result = this.restoreArchiveInTransaction(archive, archive.entries.length);
      if (!result.complete) throw new RealmStoreError("constraint");
      if (String(row.state) === "pending") {
        this.sql.exec(
          `UPDATE restore_bundle_logs SET state = 'complete' WHERE bundle_id = ? AND log_id = ?`,
          bundle.bundleId, archive.logId,
        );
        importedLogs += 1;
      }
    }

    const remaining = Number(this.sql.exec(
      `SELECT COUNT(*) AS count FROM restore_bundle_logs WHERE state <> 'complete'`,
    ).one().count);
    const complete = remaining === 0;
    if (complete) this.sql.exec(`UPDATE restore_bundles SET state = 'complete' WHERE singleton = 1`);
    return {
      importedLogs,
      skippedLogs: alreadyComplete,
      complete,
    };
  }

  takeLease(logId: string): Lease {
    try {
      return this.txn.transactionSync(() => {
        this.requireNoPendingRestoreBundle();
        const log = this.requireLog(logId);
        this.requireRestoreComplete(logId);
        const epoch = Number(log.lease_epoch);
        const writerId = log.document_writer_id === null
          ? crypto.randomUUID().toLowerCase()
          : String(log.document_writer_id);
        const rows = this.sql
          .exec(
            `UPDATE logs
             SET lease_epoch = lease_epoch + 1,
                 document_writer_id = COALESCE(document_writer_id, ?)
             WHERE log_id = ? AND lease_epoch = ?
             RETURNING lease_epoch, document_writer_id`,
            writerId,
            logId,
            epoch,
          )
          .toArray();
        if (rows[0] === undefined) throw new RealmStoreError("stale_epoch");
        return {
          leaseEpoch: Number(rows[0].lease_epoch),
          writerId: String(rows[0].document_writer_id),
        };
      });
    } catch (error) {
      translateStorageError(error);
    }
  }

  readSet(logId: string, query: ReadQuery): RealmReadSet {
    return this.txn.transactionSync(() => {
      this.requireNoPendingRestoreBundle();
      const log = this.requireLog(logId);
      this.requireRestoreComplete(logId);
      const tips = query.writers.length === 0
        ? []
        : this.sql
            .exec(
              `SELECT writer_id, last_seq, last_entry_id FROM writer_tips
               WHERE log_id = ? AND writer_id IN (${placeholders(query.writers)}) ORDER BY writer_id`,
              logId,
              ...query.writers,
            )
            .toArray()
            .map((row) => ({
              writerId: String(row.writer_id),
              lastSeq: Number(row.last_seq),
              lastEntryId: String(row.last_entry_id),
            }));

      const coordinateClauses = query.coordinates.map(() => "(writer_id = ? AND writer_seq = ?)");
      const coordinateParams = query.coordinates.flatMap((coordinate) => [
        coordinate.writerId,
        coordinate.writerSeq,
      ]);
      const coordinates = coordinateClauses.length === 0
        ? []
        : this.sql
            .exec(
              `SELECT writer_id, writer_seq, canonical_json FROM entries
               WHERE log_id = ? AND (${coordinateClauses.join(" OR ")})
               ORDER BY writer_id, writer_seq`,
              logId,
              ...coordinateParams,
            )
            .toArray()
            .map((row) => ({
              writerId: String(row.writer_id),
              writerSeq: Number(row.writer_seq),
              canonicalBytes: bytes(row.canonical_json),
            }));

      const entryIds = query.entryIds.length === 0
        ? []
        : this.sql
            .exec(
              `SELECT entry_id, canonical_json FROM entries
               WHERE log_id = ? AND entry_id IN (${placeholders(query.entryIds)}) ORDER BY entry_id`,
              logId,
              ...query.entryIds,
            )
            .toArray()
            .map((row) => ({ entryId: String(row.entry_id), canonicalBytes: bytes(row.canonical_json) }));

      return {
        logId,
        formatVersion: Number(log.format_version),
        revision: Number(log.revision),
        leaseEpoch: Number(log.lease_epoch),
        documentWriterId: log.document_writer_id === null ? null : String(log.document_writer_id),
        tips,
        coordinates,
        entryIds,
      };
    });
  }

  commit(plan: CommitPlan): number {
    try {
      return this.txn.transactionSync(() => {
        this.requireNoPendingRestoreBundle();
        const log = this.requireLog(plan.logId);
        this.requireRestoreComplete(plan.logId);
        if (Number(log.revision) !== plan.expectedRevision) {
          throw new RealmStoreError("stale_revision");
        }
        if (Number(log.lease_epoch) !== plan.expectedEpoch) {
          throw new RealmStoreError("obsolete_epoch");
        }

        for (const entry of plan.insertEntries) {
          const receivedAtMs = Date.now();
          this.sql.exec(
            `INSERT INTO entries
               (log_id, entry_id, writer_id, writer_seq, prev_entry_id, created_at,
                canonical_json, received_at_ms)
             VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
            plan.logId,
            entry.entryId,
            entry.writerId,
            entry.writerSeq,
            entry.prevEntryId,
            entry.createdAt,
            entry.canonicalBytes.buffer.slice(
              entry.canonicalBytes.byteOffset,
              entry.canonicalBytes.byteOffset + entry.canonicalBytes.byteLength,
            ),
            receivedAtMs,
          );
        }

        for (const tip of plan.putTips) {
          this.sql.exec(
            `INSERT INTO writer_tips (log_id, writer_id, last_seq, last_entry_id)
             VALUES (?, ?, ?, ?)
             ON CONFLICT (log_id, writer_id) DO UPDATE SET
               last_seq = excluded.last_seq, last_entry_id = excluded.last_entry_id`,
            plan.logId,
            tip.writerId,
            tip.lastSeq,
            tip.lastEntryId,
          );
        }

        const advanced = this.sql
          .exec(
            `UPDATE logs SET revision = revision + 1
             WHERE log_id = ? AND revision = ? AND lease_epoch = ? RETURNING revision`,
            plan.logId,
            plan.expectedRevision,
            plan.expectedEpoch,
          )
          .toArray();
        if (advanced[0] === undefined) throw new RealmStoreError("stale_revision");
        return Number(advanced[0].revision);
      });
    } catch (error) {
      translateStorageError(error);
    }
  }

  /** Realm-wide inventory for its already realm-wide read capability. Keyset paginated. */
  listLogs(afterLogId: string | undefined = undefined, limit = 100): { logIds: string[]; nextAfterLogId: string | null } {
    // A created realm may have no logs yet. Reads must not create the log schema.
    if (this.sql.exec("SELECT 1 FROM sqlite_master WHERE type='table' AND name='logs'").toArray().length === 0) {
      return { logIds: [], nextAfterLogId: null };
    }
    const rows = (afterLogId === undefined
      ? this.sql.exec("SELECT log_id FROM logs ORDER BY log_id LIMIT ?", limit + 1)
      : this.sql.exec("SELECT log_id FROM logs WHERE log_id > ? ORDER BY log_id LIMIT ?", afterLogId, limit + 1)
    ).toArray();
    const logIds = rows.slice(0, limit).map((row) => String(row.log_id));
    return { logIds, nextAfterLogId: rows.length > limit ? logIds.at(-1) ?? null : null };
  }

  frontier(logId: string): { writers: Array<{ writerId: string; seq: number; entryId: string }> } {
    this.requireNoPendingRestoreBundle();
    this.requireLog(logId);
    this.requireRestoreComplete(logId);
    const writers = this.sql
      .exec(
        `SELECT writer_id, last_seq, last_entry_id FROM writer_tips
         WHERE log_id = ? ORDER BY writer_id`,
        logId,
      )
      .toArray()
      .map((row) => ({
        writerId: String(row.writer_id),
        seq: Number(row.last_seq),
        entryId: String(row.last_entry_id),
      }));
    return { writers };
  }

  readWriter(logId: string, writerId: string, options: ReadWriterOptions): {
    entries: Array<{ canonicalBytes: Uint8Array; writerSeq: number }>;
    nextAfterSeq: number | null;
  } {
    this.requireNoPendingRestoreBundle();
    this.requireLog(logId);
    this.requireRestoreComplete(logId);
    const through = options.throughSeq === undefined ? "" : " AND writer_seq <= ?";
    const params = options.throughSeq === undefined
      ? [logId, writerId, options.afterSeq, options.limit + 1]
      : [logId, writerId, options.afterSeq, options.throughSeq, options.limit + 1];
    const rows = this.sql
      .exec(
        `SELECT canonical_json, writer_seq FROM entries
         WHERE log_id = ? AND writer_id = ? AND writer_seq > ?${through}
         ORDER BY writer_seq LIMIT ?`,
        ...params,
      )
      .toArray();
    const more = rows.length > options.limit;
    const page = rows.slice(0, options.limit);
    const entries = page.map((row) => ({
      canonicalBytes: bytes(row.canonical_json),
      writerSeq: Number(row.writer_seq),
    }));
    return {
      entries,
      nextAfterSeq: more ? entries.at(-1)!.writerSeq : null,
    };
  }

  tailLocal(logId: string, options: TailLocalOptions): {
    entries: Array<{ canonicalBytes: Uint8Array; arrivalSeq: number }>;
    nextAfterArrival: number | null;
  } {
    this.requireNoPendingRestoreBundle();
    this.requireLog(logId);
    this.requireRestoreComplete(logId);
    const rows = this.sql
      .exec(
        `SELECT canonical_json, arrival_seq FROM entries
         WHERE log_id = ? AND arrival_seq > ? ORDER BY arrival_seq LIMIT ?`,
        logId,
        options.afterArrival,
        options.limit + 1,
      )
      .toArray();
    const more = rows.length > options.limit;
    const page = rows.slice(0, options.limit);
    const entries = page.map((row) => ({
      canonicalBytes: bytes(row.canonical_json),
      arrivalSeq: Number(row.arrival_seq),
    }));
    return {
      entries,
      nextAfterArrival: more ? entries.at(-1)!.arrivalSeq : null,
    };
  }

  private requireLog(logId: string): Record<string, unknown> {
    const hasLogs = this.sql
      .exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'logs'")
      .toArray().length > 0;
    if (!hasLogs) throw new RealmStoreError("not_found");
    const row = this.sql
      .exec(
        `SELECT log_id, format_version, revision, lease_epoch, document_writer_id, created_at
         FROM logs WHERE log_id = ?`,
        logId,
      )
      .toArray()[0];
    if (row === undefined) throw new RealmStoreError("not_found");
    return row;
  }

  private requireRestoreComplete(logId: string): void {
    const row = this.sql.exec(`SELECT state FROM restore_markers WHERE log_id = ?`, logId).toArray()[0];
    if (row !== undefined && String(row.state) !== "complete") throw new RealmStoreError("obsolete_epoch");
  }

  /**
   * Inventory is read-only, so it uses a bounded version of the normal bundle
   * fence. The normal helper intentionally materializes restore manifests for
   * restore/reconciliation; listing must preflight every count and blob length
   * before selecting any variable-sized field.
   */
  private requireInventoryRestoreState(): void {
    const hasBundles = hasSqlTable(this.sql, "restore_bundles");
    const hasInventory = hasSqlTable(this.sql, "restore_bundle_logs");
    if (!hasBundles) {
      if (hasInventory) throw new RealmStoreError("obsolete_epoch");
      return;
    }
    if (!hasInventory) throw new RealmStoreError("obsolete_epoch");
    if (!hasSqlTable(this.sql, "restore_markers")) throw new RealmStoreError("obsolete_epoch");

    const bundleCount = Number(this.sql.exec("SELECT COUNT(*) AS count FROM restore_bundles").one().count);
    const inventoryCount = Number(this.sql.exec("SELECT COUNT(*) AS count FROM restore_bundle_logs").one().count);
    if (bundleCount === 0) {
      if (inventoryCount !== 0) throw new RealmStoreError("obsolete_epoch");
      return;
    }
    if (bundleCount !== 1) throw new RealmStoreError("obsolete_epoch");

    const bundle = this.sql.exec(
      `SELECT singleton, substr(bundle_id, 1, ?) AS bundle_id, log_count,
              length(CAST(bundle_id AS BLOB)) AS bundle_id_bytes,
              length(digest) AS digest_bytes, substr(state, 1, 16) AS state
       FROM restore_bundles LIMIT 2`,
      MAX_RESTORE_ID_BYTES + 1,
    ).toArray();
    const storedBundle = bundle[0];
    if (bundle.length !== 1 || storedBundle === undefined) throw new RealmStoreError("obsolete_epoch");
    const logCount = Number(storedBundle.log_count);
    if (Number(storedBundle.singleton) !== 1 || !boundedRestoreId(storedBundle.bundle_id) ||
        Number(storedBundle.bundle_id_bytes) > MAX_RESTORE_ID_BYTES ||
        !Number.isInteger(logCount) || logCount < 1 || logCount > MAX_BUNDLE_LOGS ||
        Number(storedBundle.digest_bytes) !== 32 || String(storedBundle.state) !== "complete" ||
        inventoryCount !== logCount) {
      throw new RealmStoreError("obsolete_epoch");
    }

    const bundleId = String(storedBundle.bundle_id);
    const inventorySummary = this.sql.exec(
      `SELECT COUNT(*) AS count,
              COALESCE(SUM(length(CAST(bundle_id AS BLOB)) + length(CAST(log_id AS BLOB)) +
                length(CAST(archive_id AS BLOB)) + length(CAST(writer_id AS BLOB)) +
                length(CAST(entry_count AS BLOB)) + length(CAST(total_bytes AS BLOB)) + 32 + 1), 0) AS bytes,
              COALESCE(SUM(CASE WHEN state <> 'complete' THEN 1 ELSE 0 END), 0) AS bad_state,
              COALESCE(MAX(length(CAST(log_id AS BLOB))), 0) AS max_log_id_bytes,
              COALESCE(MAX(length(CAST(archive_id AS BLOB))), 0) AS max_archive_id_bytes,
              COALESCE(MAX(length(CAST(writer_id AS BLOB))), 0) AS max_writer_id_bytes,
              COALESCE(MAX(length(CAST(state AS BLOB))), 0) AS max_state_bytes,
              COALESCE(MAX(length(digest)), 0) AS max_digest_bytes
       FROM restore_bundle_logs WHERE bundle_id = ?`, bundleId,
    ).one();
    if (Number(inventorySummary.count) !== logCount || Number(inventorySummary.bad_state) !== 0 ||
        Number(inventorySummary.bytes) > MAX_INVENTORY_BYTES ||
        Number(inventorySummary.max_log_id_bytes) > MAX_RESTORE_ID_BYTES ||
        Number(inventorySummary.max_archive_id_bytes) > MAX_RESTORE_ID_BYTES ||
        Number(inventorySummary.max_writer_id_bytes) > MAX_RESTORE_ID_BYTES ||
        Number(inventorySummary.max_state_bytes) > 16 || Number(inventorySummary.max_digest_bytes) !== 32) {
      throw new RealmStoreError("obsolete_epoch");
    }
    if (this.sql.exec(
      `SELECT 1 FROM restore_bundle_logs WHERE bundle_id <> ? LIMIT 1`, bundleId,
    ).toArray().length > 0) throw new RealmStoreError("obsolete_epoch");

    const inventoryRows = this.sql.exec(
      `SELECT substr(bundle_id, 1, ?) AS bundle_id, substr(log_id, 1, ?) AS log_id,
              substr(archive_id, 1, ?) AS archive_id, substr(writer_id, 1, ?) AS writer_id,
              entry_count, total_bytes, substr(digest, 1, 33) AS digest, substr(state, 1, 16) AS state,
              length(CAST(log_id AS BLOB)) AS log_id_bytes,
              length(CAST(archive_id AS BLOB)) AS archive_id_bytes,
              length(CAST(writer_id AS BLOB)) AS writer_id_bytes,
              length(digest) AS digest_bytes
       FROM restore_bundle_logs WHERE bundle_id = ? ORDER BY log_id LIMIT ?`,
      MAX_RESTORE_ID_BYTES + 1, MAX_RESTORE_ID_BYTES + 1, MAX_RESTORE_ID_BYTES + 1,
      MAX_RESTORE_ID_BYTES + 1, bundleId, MAX_BUNDLE_LOGS + 1,
    ).toArray();
    if (inventoryRows.length !== logCount || inventoryRows.some((row) =>
      String(row.state) === "pending" || String(row.bundle_id) !== bundleId ||
      !boundedRestoreId(row.log_id) || !boundedRestoreId(row.archive_id) || !boundedRestoreId(row.writer_id) ||
      Number(row.log_id_bytes) > MAX_RESTORE_ID_BYTES || Number(row.archive_id_bytes) > MAX_RESTORE_ID_BYTES ||
      Number(row.writer_id_bytes) > MAX_RESTORE_ID_BYTES || Number(row.digest_bytes) !== 32 ||
      !Number.isSafeInteger(Number(row.entry_count)) || Number(row.entry_count) < 0 ||
      !Number.isSafeInteger(Number(row.total_bytes)) || Number(row.total_bytes) < 0 ||
      (Number(row.entry_count) === 0 && Number(row.total_bytes) !== 0))) {
      throw new RealmStoreError("obsolete_epoch");
    }

    const logIds = inventoryRows.map((row) => String(row.log_id));
    if (new Set(logIds).size !== logIds.length) throw new RealmStoreError("obsolete_epoch");
    const clauses = logIds.map(() => "?").join(", ");
    const markerSummary = this.sql.exec(
      `SELECT COUNT(*) AS count, COALESCE(SUM(length(manifest_json)), 0) AS bytes,
              COALESCE(MAX(length(manifest_json)), 0) AS max_bytes,
              COALESCE(MAX(length(CAST(archive_id AS BLOB))), 0) AS max_archive_id_bytes,
              COALESCE(MAX(length(CAST(writer_id AS BLOB))), 0) AS max_writer_id_bytes,
              COALESCE(MAX(length(CAST(state AS BLOB))), 0) AS max_state_bytes
       FROM restore_markers WHERE log_id IN (${clauses})`, ...logIds,
    ).one();
    if (Number(markerSummary.count) !== logCount || Number(markerSummary.bytes) > MAX_INVENTORY_BYTES ||
        Number(markerSummary.max_bytes) !== RESTORE_MARKER_PREFIX.byteLength + RESTORE_MARKER_DIGEST_BYTES ||
        Number(markerSummary.max_archive_id_bytes) > MAX_RESTORE_ID_BYTES ||
        Number(markerSummary.max_writer_id_bytes) > MAX_RESTORE_ID_BYTES ||
        Number(markerSummary.max_state_bytes) > 16) {
      throw new RealmStoreError("obsolete_epoch");
    }
    const markers = this.sql.exec(
      `SELECT substr(rm.log_id, 1, ?) AS log_id, substr(rm.archive_id, 1, ?) AS archive_id,
              substr(rm.writer_id, 1, ?) AS writer_id, rm.entry_count, rm.total_bytes,
              substr(rm.state, 1, 16) AS state, substr(rm.manifest_json, 1, ?) AS manifest_json
       FROM restore_markers rm WHERE rm.log_id IN (${clauses}) ORDER BY rm.log_id LIMIT ?`,
      MAX_RESTORE_ID_BYTES + 1, MAX_RESTORE_ID_BYTES + 1, MAX_RESTORE_ID_BYTES + 1,
      RESTORE_MARKER_PREFIX.byteLength + RESTORE_MARKER_DIGEST_BYTES, ...logIds, MAX_BUNDLE_LOGS + 1,
    ).toArray();
    if (markers.length !== logCount || markers.some((marker) => {
      const inventoryRow = inventoryRows.find((row) => String(row.log_id) === String(marker.log_id));
      return inventoryRow === undefined || String(marker.state) !== "complete" ||
        String(marker.archive_id) !== String(inventoryRow.archive_id) ||
        String(marker.writer_id) !== String(inventoryRow.writer_id) ||
        Number(marker.entry_count) !== Number(inventoryRow.entry_count) ||
        Number(marker.total_bytes) !== Number(inventoryRow.total_bytes) ||
        !compactMarkerContainsDigest(bytes(marker.manifest_json), bytes(inventoryRow.digest));
    })) throw new RealmStoreError("obsolete_epoch");
  }

  private requireNoPendingRestoreBundle(): void {
    const hasBundles = hasSqlTable(this.sql, "restore_bundles");
    const hasInventory = hasSqlTable(this.sql, "restore_bundle_logs");
    if (!hasBundles) {
      if (hasInventory) throw new RealmStoreError("obsolete_epoch");
      return;
    }
    if (!hasInventory) throw new RealmStoreError("obsolete_epoch");
    const bundles = this.sql.exec(
      `SELECT singleton, bundle_id, log_count, digest, state FROM restore_bundles ORDER BY singleton`,
    ).toArray();
    const inventory = this.sql.exec(
      `SELECT bundle_id, log_id, archive_id, writer_id, entry_count, total_bytes, digest, state
       FROM restore_bundle_logs ORDER BY log_id`,
    ).toArray();
    if (bundles.length === 0) {
      if (inventory.length > 0) throw new RealmStoreError("obsolete_epoch");
      return;
    }
    if (bundles.length !== 1) throw new RealmStoreError("obsolete_epoch");
    const bundle = bundles[0];
    if (bundle === undefined || Number(bundle.singleton) !== 1 ||
        !boundedRestoreId(bundle.bundle_id) || bytes(bundle.digest).byteLength !== 32 ||
        !Number.isInteger(Number(bundle.log_count)) || Number(bundle.log_count) < 1 || Number(bundle.log_count) > MAX_BUNDLE_LOGS ||
        (String(bundle.state) !== "pending" && String(bundle.state) !== "complete") ||
        inventory.length !== Number(bundle.log_count) ||
        inventory.some((row) => String(row.bundle_id) !== String(bundle.bundle_id) || String(row.state) !== "complete")) {
      throw new RealmStoreError("obsolete_epoch");
    }
    const logIds = inventory.map((row) => String(row.log_id));
    const clauses = logIds.map(() => "?").join(", ");
    const logs = this.sql.exec(`SELECT log_id FROM logs WHERE log_id IN (${clauses})`, ...logIds).toArray();
    const markers = this.sql.exec(
      `SELECT log_id, archive_id, writer_id, entry_count, total_bytes, manifest_json, state
       FROM restore_markers WHERE log_id IN (${clauses})`, ...logIds,
    ).toArray();
    if (logs.length !== logIds.length || markers.length !== logIds.length ||
        markers.some((row) => {
          const inventoryRow = inventory.find((item) => String(item.log_id) === String(row.log_id));
          return inventoryRow === undefined || String(row.state) !== "complete" ||
            String(row.archive_id) !== String(inventoryRow.archive_id) ||
            String(row.writer_id) !== String(inventoryRow.writer_id) ||
            Number(row.entry_count) !== Number(inventoryRow.entry_count) ||
            Number(row.total_bytes) !== Number(inventoryRow.total_bytes) ||
            !compactMarkerContainsDigest(bytes(row.manifest_json), bytes(inventoryRow.digest));
        })) {
      throw new RealmStoreError("obsolete_epoch");
    }
    if (String(bundle.state) === "pending") throw new RealmStoreError("obsolete_epoch");
  }

  private requireEmptyTargetForBundle(): void {
    for (const table of ["logs", "entries", "writer_tips", "restore_markers", "restore_bundles", "restore_bundle_logs"]) {
      if (hasSqlTable(this.sql, table) && Number(this.sql.exec(`SELECT COUNT(*) AS count FROM ${table}`).one().count) !== 0) {
        throw new RealmStoreError("constraint");
      }
    }
  }

  private rejectUnexpectedPendingBundleRows(bundle: RestoreBundle): void {
    const expected = new Set(bundle.logs.map((archive) => archive.logId));
    for (const table of ["logs", "entries", "writer_tips", "restore_markers"]) {
      const rows = this.sql.exec(`SELECT DISTINCT log_id FROM ${table}`).toArray();
      if (rows.some((row) => !expected.has(String(row.log_id)))) throw new RealmStoreError("constraint");
    }
  }

  private verifyBundleRecord(
    storedBundle: Record<string, unknown>,
    inventoryRows: Array<Record<string, unknown>>,
    bundle: RestoreBundle,
    digest: Uint8Array,
  ): void {
    if (String(storedBundle.bundle_id) !== bundle.bundleId ||
        Number(storedBundle.log_count) !== bundle.logs.length ||
        !sameBytes(bytes(storedBundle.digest), digest) ||
        (String(storedBundle.state) !== "pending" && String(storedBundle.state) !== "complete") ||
        inventoryRows.length !== bundle.logs.length ||
        (String(storedBundle.state) === "complete" && inventoryRows.some((row) => String(row.state) !== "complete"))) {
      throw new RealmStoreError("constraint");
    }
    const expected = new Map(bundle.logs.map((archive) => [archive.logId, archive]));
    for (const row of inventoryRows) {
      const archive = expected.get(String(row.log_id));
      if (archive === undefined || String(row.bundle_id) !== bundle.bundleId ||
          String(row.archive_id) !== archive.archiveId || String(row.writer_id) !== archive.writerId ||
          Number(row.entry_count) !== archive.entries.length ||
          Number(row.total_bytes) !== archive.entries.reduce((sum, entry) => sum + entry.canonicalBytes.byteLength, 0) ||
          !sameBytes(bytes(row.digest), restoreManifestDigest(archive)) ||
          (String(row.state) !== "pending" && String(row.state) !== "complete")) {
        throw new RealmStoreError("constraint");
      }
      expected.delete(archive.logId);
    }
    if (expected.size !== 0) throw new RealmStoreError("constraint");
  }
}

function hasSqlTable(sql: SqlStorage, name: string): boolean {
  return sql.exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", name).toArray().length > 0;
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  return left.byteLength === right.byteLength && left.every((byte, index) => byte === right[index]);
}

function validateRestoreArchive(archive: RestoreArchive, maxEntries: number): void {
  if (!Number.isSafeInteger(maxEntries) || maxEntries < 1 || maxEntries > 4096 ||
      archive.entries.length > 4096 ||
      !boundedRestoreId(archive.logId) || !boundedRestoreId(archive.archiveId) ||
      !boundedRestoreId(archive.writerId)) {
    throw new RealmStoreError("constraint");
  }
  const ids = new Set<string>();
  let totalBytes = 0;
  let previous: EntryRow | undefined;
  for (const entry of archive.entries) {
    if (entry.writerId !== archive.writerId || ids.has(entry.entryId)) throw new RealmStoreError("constraint");
    ids.add(entry.entryId);
    totalBytes += entry.canonicalBytes.byteLength;
    if (totalBytes > 16 * 1024 * 1024) throw new RealmStoreError("constraint");
    // Structural only: canonical/semantic entry validation is the restore caller's job (proposal §9).
    let parsed: Record<string, unknown>;
    try {
      const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(entry.canonicalBytes));
      if (typeof value !== "object" || value === null || Array.isArray(value)) throw new RealmStoreError("constraint");
      parsed = value as Record<string, unknown>;
    } catch {
      throw new RealmStoreError("constraint");
    }
    if (parsed.log_id !== archive.logId || parsed.entry_id !== entry.entryId || parsed.writer_id !== entry.writerId ||
        parsed.writer_seq !== entry.writerSeq || parsed.prev_entry_id !== entry.prevEntryId || parsed.created_at !== entry.createdAt ||
        (previous === undefined && (entry.writerSeq !== 1 || entry.prevEntryId !== null)) ||
        (previous !== undefined && (entry.writerSeq !== previous.writerSeq + 1 || entry.prevEntryId !== previous.entryId))) {
      throw new RealmStoreError("constraint");
    }
    previous = entry;
  }
}

function validateRestoreBundle(bundle: RestoreBundle, maxLogs: number): void {
  if (!Number.isSafeInteger(maxLogs) || maxLogs < 1 || maxLogs > MAX_BUNDLE_LOGS ||
      !boundedRestoreId(bundle.bundleId) || !Array.isArray(bundle.logs) ||
      bundle.logs.length === 0 || bundle.logs.length > MAX_BUNDLE_LOGS) {
    throw new RealmStoreError("constraint");
  }
  let totalBytes = 0;
  let previousLogId: string | undefined;
  // Inventory policy: callers provide logs in strictly ascending log_id order.
  for (const archive of bundle.logs) {
    validateRestoreArchive(archive, 4096);
    if (previousLogId !== undefined && archive.logId <= previousLogId) throw new RealmStoreError("constraint");
    previousLogId = archive.logId;
    totalBytes += archive.entries.reduce((sum, entry) => sum + entry.canonicalBytes.byteLength, 0);
    if (totalBytes > 16 * 1024 * 1024) throw new RealmStoreError("constraint");
  }
}

function boundedRestoreId(value: unknown): value is string {
  return typeof value === "string" && value.length > 0 &&
    UTF8.encode(value).byteLength <= MAX_RESTORE_ID_BYTES;
}

function updateFrameLength(hash: ReturnType<typeof createHash>, length: number): void {
  const frame = new Uint8Array(4);
  new DataView(frame.buffer).setUint32(0, length);
  hash.update(frame);
}

function updateFrameText(hash: ReturnType<typeof createHash>, value: string): void {
  const encoded = UTF8.encode(value);
  updateFrameLength(hash, encoded.byteLength);
  hash.update(encoded);
}

function restoreManifestDigest(archive: RestoreArchive): Uint8Array {
  const hash = createHash("sha256");
  hash.update(RESTORE_MARKER_PREFIX);
  updateFrameText(hash, archive.logId);
  updateFrameText(hash, archive.archiveId);
  updateFrameText(hash, archive.writerId);
  updateFrameLength(hash, archive.entries.length);
  for (const entry of archive.entries) {
    updateFrameLength(hash, entry.canonicalBytes.byteLength);
    hash.update(entry.canonicalBytes);
  }
  return new Uint8Array(hash.digest());
}

function restoreBundleDigest(bundle: RestoreBundle): Uint8Array {
  const hash = createHash("sha256");
  hash.update(BUNDLE_MARKER_PREFIX);
  updateFrameText(hash, bundle.bundleId);
  updateFrameLength(hash, bundle.logs.length);
  for (const archive of bundle.logs) hash.update(restoreManifestDigest(archive));
  return new Uint8Array(hash.digest());
}

function inventoryDigest(logs: LogInventoryRow[]): string {
  const hash = createHash("sha256");
  hash.update(INVENTORY_MARKER_PREFIX);
  updateFrameLength(hash, logs.length);
  for (const log of logs) {
    updateFrameText(hash, log.logId);
    updateFrameLength(hash, log.formatVersion);
    updateFrameLength(hash, log.revision);
    updateFrameText(hash, log.createdAt);
    updateFrameText(hash, log.documentWriterId ?? "");
    updateFrameLength(hash, log.writers.length);
    for (const writer of log.writers) {
      updateFrameText(hash, writer.writerId);
      updateFrameLength(hash, writer.lastSeq);
      updateFrameText(hash, writer.lastEntryId);
    }
  }
  return hash.digest("hex");
}

function compactMarkerContainsDigest(marker: Uint8Array, digest: Uint8Array): boolean {
  return marker.byteLength === RESTORE_MARKER_PREFIX.byteLength + RESTORE_MARKER_DIGEST_BYTES &&
    sameBytes(marker.slice(0, RESTORE_MARKER_PREFIX.byteLength), RESTORE_MARKER_PREFIX) &&
    sameBytes(marker.slice(RESTORE_MARKER_PREFIX.byteLength), digest);
}

function restoreManifest(archive: RestoreArchive): Uint8Array {
  const digest = restoreManifestDigest(archive);
  const marker = new Uint8Array(RESTORE_MARKER_PREFIX.byteLength + RESTORE_MARKER_DIGEST_BYTES);
  marker.set(RESTORE_MARKER_PREFIX);
  marker.set(digest, RESTORE_MARKER_PREFIX.byteLength);
  return marker;
}

function matchesRestoreManifest(
  stored: Uint8Array,
  archive: RestoreArchive,
  totalBytes: number,
  compact: Uint8Array,
): boolean {
  if (sameBytes(stored, compact)) return true;
  // A legacy JSON marker cannot be smaller than the canonical bytes it embeds.
  // This check avoids materializing an old whole-archive manifest for large data.
  if (stored[0] !== 0x7b || stored.byteLength > MAX_LEGACY_MARKER_BYTES || totalBytes > stored.byteLength) {
    return false;
  }
  return sameBytes(stored, legacyRestoreManifest(archive));
}

function legacyRestoreManifest(archive: RestoreArchive): Uint8Array {
  const value = {
    logId: archive.logId,
    archiveId: archive.archiveId,
    writerId: archive.writerId,
    entries: archive.entries.map((entry) => ({
      entryId: entry.entryId,
      writerId: entry.writerId,
      writerSeq: entry.writerSeq,
      prevEntryId: entry.prevEntryId,
      createdAt: entry.createdAt,
      canonicalBytes: Array.from(entry.canonicalBytes),
    })),
  };
  return new TextEncoder().encode(JSON.stringify(value));
}
