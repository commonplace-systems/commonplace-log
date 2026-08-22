/**
 * SP2 Task 4: the store's createLog (§9.1) and append (§9.2) over the §12
 * SQLite layout.
 *
 * Correctness state lives ONLY in SQLite (§15.2): this class keeps no
 * in-memory tips cache, so every operation reads current truth from the
 * database inside its transaction. Entries pass through SP1's validateEntry
 * before insertion — the store never invents its own validation or byte
 * encoding (`canonicalize` produces the object's bytes; validateEntry
 * re-derives and returns the canonical bytes that get stored).
 */
import { validateEntry } from "../entry";
import { canonicalize } from "../jcs";
import { initSchema } from "./schema";
import { uuidv7 } from "./uuid";

export type StoreErrorCode =
  | "log_mismatch"
  | "log_not_found"
  | "invalid_entry"
  | "entry_too_large";

export class StoreError extends Error {
  constructor(
    readonly code: StoreErrorCode,
    readonly details?: unknown,
  ) {
    super(code);
    this.name = "StoreError";
  }
}

/** The appended entry, parsed, plus the exact canonical bytes stored. */
export interface AppendedEntry {
  version: 1;
  logId: string;
  entryId: string;
  writerId: string;
  writerSeq: number;
  prevEntryId: string | null;
  createdAt: string;
  body: unknown;
  canonicalBytes: Uint8Array;
}

export interface AppendResult {
  entry: AppendedEntry;
  /** Local arrival metadata (§8 invariant 11) — never part of entry identity. */
  arrivalSeq: number;
}

interface Transactor {
  transactionSync<T>(fn: () => T): T;
}

export class LogStore {
  constructor(
    private readonly sql: SqlStorage,
    private readonly txn: Transactor,
  ) {}

  /**
   * §9.1: create log metadata and storage schema. Idempotent; reusing the
   * physical store for a different log_id fails with log_mismatch.
   */
  createLog(logId: string): void {
    this.txn.transactionSync(() => {
      initSchema(this.sql);
      const existing = this.readLogId();
      if (existing === null) {
        this.sql.exec(
          `INSERT INTO log_meta (singleton, log_id, format_version, created_at)
           VALUES (1, ?, 1, ?)`,
          logId,
          new Date().toISOString(),
        );
        return;
      }
      if (existing !== logId) {
        throw new StoreError("log_mismatch", {
          existingLogId: existing,
          requestedLogId: logId,
        });
      }
    });
  }

  /**
   * §9.2: the eight append steps, all inside ONE transaction — sequence
   * allocation and insertion are never separated (§8 invariants 2, 5–7, 10).
   */
  append(writerId: string, body: unknown, createdAt: string): AppendResult {
    return this.txn.transactionSync(() => {
      const logId = this.readLogId();
      if (logId === null) {
        throw new StoreError("log_not_found", { writerId });
      }

      // Steps 1–2: read the writer's tip from SQLite truth; allocate tip+1.
      const tipRows = this.sql
        .exec(
          "SELECT last_seq, last_entry_id FROM writer_tips WHERE writer_id = ?",
          writerId,
        )
        .toArray();
      const tip = tipRows[0];
      const writerSeq = tip === undefined ? 1 : Number(tip.last_seq) + 1;

      // Step 3: generate the entry_id before any storage attempt (§6.3).
      const entryId = uuidv7();

      // Step 4: prev is the tip's UUID, or null for entry 1.
      const prevEntryId = tip === undefined ? null : String(tip.last_entry_id);

      // Step 5: build the full version-1 entry and pass it through SP1's
      // validator — the only place entry validity is decided.
      const entry = {
        version: 1,
        log_id: logId,
        entry_id: entryId,
        writer_id: writerId,
        writer_seq: writerSeq,
        prev_entry_id: prevEntryId,
        created_at: createdAt,
        body,
      };
      let entryBytes: Uint8Array;
      try {
        entryBytes = canonicalize(entry);
      } catch (error) {
        // Non-canonicalizable input (non-finite number, undefined, bigint…).
        throw new StoreError("invalid_entry", {
          reason: error instanceof Error ? error.message : String(error),
        });
      }
      const validated = validateEntry(entryBytes);
      if (!validated.ok) {
        throw new StoreError(
          validated.code === "entry_too_large" ? "entry_too_large" : "invalid_entry",
          { reason: validated.reason },
        );
      }
      const canonicalBytes = validated.canonicalBytes;

      // Steps 6 + 8: insert the canonical bytes; arrival_seq comes from the
      // inserted row itself, received_at_ms is local receipt time.
      const receivedAtMs = Date.now();
      const inserted = this.sql
        .exec(
          `INSERT INTO entries
             (entry_id, writer_id, writer_seq, prev_entry_id, created_at,
              canonical_json, received_at_ms)
           VALUES (?, ?, ?, ?, ?, ?, ?)
           RETURNING arrival_seq`,
          entryId,
          writerId,
          writerSeq,
          prevEntryId,
          createdAt,
          toArrayBuffer(canonicalBytes),
          receivedAtMs,
        )
        .one();
      const arrivalSeq = Number(inserted.arrival_seq);

      // Step 7: advance the writer tip in the same transaction.
      this.sql.exec(
        `INSERT INTO writer_tips (writer_id, last_seq, last_entry_id)
         VALUES (?, ?, ?)
         ON CONFLICT (writer_id) DO UPDATE
           SET last_seq = excluded.last_seq,
               last_entry_id = excluded.last_entry_id`,
        writerId,
        writerSeq,
        entryId,
      );

      return {
        entry: {
          version: 1 as const,
          logId,
          entryId,
          writerId,
          writerSeq,
          prevEntryId,
          createdAt,
          body,
          canonicalBytes,
        },
        arrivalSeq,
      };
    });
  }

  /** The log's identity from log_meta, or null when the store is uncreated. */
  private readLogId(): string | null {
    let rows: Record<string, unknown>[];
    try {
      rows = this.sql.exec("SELECT log_id FROM log_meta WHERE singleton = 1").toArray();
    } catch (error) {
      // Before createLog the schema may not exist at all — same answer as an
      // empty log_meta: there is no log here.
      if (error instanceof Error && /no such table/i.test(error.message)) {
        return null;
      }
      throw error;
    }
    const row = rows[0];
    return row === undefined ? null : String(row.log_id);
  }
}

/** Exact-length ArrayBuffer for BLOB binding (never hand over a larger backing buffer). */
function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  return bytes.buffer.slice(
    bytes.byteOffset,
    bytes.byteOffset + bytes.byteLength,
  ) as ArrayBuffer;
}
