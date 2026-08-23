import { initSchema } from "./schema";

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
  receivedAtMs: number;
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

  takeLease(logId: string): number {
    try {
      return this.txn.transactionSync(() => {
        const log = this.requireLog(logId);
        const epoch = Number(log.lease_epoch);
        const rows = this.sql
          .exec(
            `UPDATE logs SET lease_epoch = lease_epoch + 1
             WHERE log_id = ? AND lease_epoch = ? RETURNING lease_epoch`,
            logId,
            epoch,
          )
          .toArray();
        if (rows[0] === undefined) throw new RealmStoreError("stale_epoch");
        return Number(rows[0].lease_epoch);
      });
    } catch (error) {
      translateStorageError(error);
    }
  }

  readSet(logId: string, query: ReadQuery): RealmReadSet {
    return this.txn.transactionSync(() => {
      const log = this.requireLog(logId);
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
        if (Number(log.revision) !== plan.expectedRevision) {
          throw new RealmStoreError("stale_revision");
        }
        if (Number(log.lease_epoch) !== plan.expectedEpoch) {
          throw new RealmStoreError("obsolete_epoch");
        }

        for (const entry of plan.insertEntries) {
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
            entry.receivedAtMs,
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
        "SELECT log_id, format_version, revision, lease_epoch, created_at FROM logs WHERE log_id = ?",
        logId,
      )
      .toArray()[0];
    if (row === undefined) throw new RealmStoreError("not_found");
    return row;
  }
}
