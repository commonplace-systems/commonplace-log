import { initSchema } from "./schema";
import { validateEntry } from "../entry";

export type RealmStorageErrorCode =
  | "not_found"
  | "stale_epoch"
  | "stale_revision"
  | "obsolete_epoch"
  | "constraint"
  | "storage_full";

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
    const totalBytes = archive.entries.reduce((sum, entry) => sum + entry.canonicalBytes.byteLength, 0);
    const manifest = restoreManifest(archive);
    try {
      return this.txn.transactionSync(() => {
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
          !sameBytes(bytes(marker.manifest_json), manifest) ||
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
        for (const row of rows) {
          const id = String(row.entry_id);
          const coordinate = `${String(row.writer_id)}:${Number(row.writer_seq)}`;
          if (!archiveIds.has(id) && !archiveCoordinates.has(coordinate)) {
            if (markerState !== "complete" || String(row.writer_id) !== archive.writerId ||
                Number(row.writer_seq) <= archive.entries.at(-1)!.writerSeq) {
              throw new RealmStoreError("constraint");
            }
          }
        }
        const targetTip = this.sql.exec(
          `SELECT writer_id, last_seq, last_entry_id FROM writer_tips WHERE log_id = ? ORDER BY writer_id`, archive.logId,
        ).toArray();
        if (targetTip.length > 1 || (targetTip.length === 1 && String(targetTip[0].writer_id) !== archive.writerId)) {
          throw new RealmStoreError("constraint");
        }
        for (let index = 0; index < rows.length; index += 1) {
          const row = rows[index];
          if (String(row.writer_id) !== archive.writerId || Number(row.writer_seq) !== index + 1 ||
              (index === 0 ? row.prev_entry_id !== null : String(row.prev_entry_id) !== String(rows[index - 1].entry_id))) {
            throw new RealmStoreError("constraint");
          }
        }
        if (
          (rows.length === 0 && targetTip.length !== 0) ||
          (rows.length > 0 &&
            (targetTip.length !== 1 || Number(targetTip[0].last_seq) !== rows.length ||
              String(targetTip[0].last_entry_id) !== String(rows.at(-1).entry_id)))
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
      });
    } catch (error) {
      translateStorageError(error);
    }
  }

  takeLease(logId: string): Lease {
    try {
      return this.txn.transactionSync(() => {
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

  frontier(logId: string): { writers: Array<{ writerId: string; seq: number; entryId: string }> } {
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
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  return left.byteLength === right.byteLength && left.every((byte, index) => byte === right[index]);
}

function validateRestoreArchive(archive: RestoreArchive, maxEntries: number): void {
  if (!Number.isSafeInteger(maxEntries) || maxEntries < 1 || maxEntries > 4096 ||
      archive.entries.length === 0 || archive.entries.length > 4096 ||
      archive.archiveId.length === 0 || archive.writerId.length === 0) {
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
    const checked = validateEntry(entry.canonicalBytes);
    if (!checked.ok || !sameBytes(checked.canonicalBytes, entry.canonicalBytes)) throw new RealmStoreError("constraint");
    let parsed: Record<string, unknown>;
    try {
      parsed = JSON.parse(new TextDecoder().decode(entry.canonicalBytes)) as Record<string, unknown>;
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

function restoreManifest(archive: RestoreArchive): Uint8Array {
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
