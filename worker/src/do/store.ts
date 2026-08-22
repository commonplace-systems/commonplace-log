/**
 * The store: createLog (§9.1), append (§9.2), mergeEntries (§9.3/§12.1),
 * and the reads — frontier (§9.4), readWriter (§9.5), tailLocal (§9.6) —
 * over the §12 SQLite layout.
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
import { planMerge, type BatchEntry, type TipInfo } from "./merge-plan";
import { initSchema } from "./schema";
import { uuidv7 } from "./uuid";

export type StoreErrorCode =
  | "log_mismatch"
  | "log_not_found"
  | "invalid_entry"
  | "entry_too_large"
  | "writer_gap"
  | "writer_fork"
  | "entry_id_collision";

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

/** One writer's tip in the frontier (§9.4). */
export interface FrontierEntry {
  writerId: string;
  seq: number;
  entryId: string;
}

/** §11.2 merge response arithmetic: inserted + present covers the batch. */
export interface MergeResult {
  inserted: number;
  present: number;
  /** ALL known writers' tips post-merge, sorted by writerId (§9.4). */
  frontier: FrontierEntry[];
}

/** §9.5 read_writer page: ascending contiguous writer_seq range. */
export interface ReadWriterResult {
  entries: Array<{ canonicalBytes: Uint8Array; writerSeq: number }>;
  /**
   * Continuation cursor: the last returned writer_seq when more entries
   * remain inside the requested (clamped) range, else null.
   */
  nextAfterSeq: number | null;
}

/** §9.6 tail_local page: replica-local arrival order. */
export interface TailResult {
  entries: Array<{ canonicalBytes: Uint8Array; arrivalSeq: number }>;
  /** The last returned arrival_seq when more entries remain, else null. */
  nextAfterArrival: number | null;
}

/**
 * A batch entry as the merge pipeline carries it: the classifier's fields
 * plus created_at, which the classifier deliberately ignores (§8 inv 11 —
 * timestamps never affect merge semantics) but the entries table stores.
 * planMerge returns the very objects it was given, so the extra field
 * survives the round trip through the plan.
 */
interface MergeBatchEntry extends BatchEntry {
  createdAt: string;
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

  /**
   * §12.1: the seven-step transactional batch merge. Validation and
   * classification are delegated — SP1's validateEntry decides entry
   * validity, planMerge (§9.3) decides the plan — and this method only
   * executes: it feeds the classifier from SQLite truth and applies the plan.
   * ANY exception rolls the whole batch back (§8 invariant 10).
   */
  mergeEntries(rawEntries: unknown[]): MergeResult {
    return this.txn.transactionSync(() => {
      const logId = this.readLogId();
      if (logId === null) {
        throw new StoreError("log_not_found", {});
      }

      // §12.1 step 1: validate and canonicalize the ENTIRE batch. Each raw
      // parsed-JSON value is canonicalized (same route append takes) and
      // judged solely by SP1's validator; the store adds exactly one check
      // of its own — entry.log_id against log_meta (§8 invariant 8, the
      // deliberate Task 3 deferral: the pure classifier has no log identity).
      const batch: MergeBatchEntry[] = [];
      for (const raw of rawEntries) {
        let rawBytes: Uint8Array;
        try {
          rawBytes = canonicalize(raw);
        } catch (error) {
          throw new StoreError("invalid_entry", {
            reason: error instanceof Error ? error.message : String(error),
          });
        }
        const validated = validateEntry(rawBytes);
        if (!validated.ok) {
          throw new StoreError(
            validated.code === "entry_too_large" ? "entry_too_large" : "invalid_entry",
            { reason: validated.reason },
          );
        }
        // The canonical bytes are the SINGLE source of truth for every
        // stored field AND the log_id check below. The raw caller object is
        // never re-read after canonicalize's one pass: an adversarial getter
        // can return different values per read, which previously let column
        // entry_id disagree with the id inside the row's own bytes
        // (regression-tested in merge.test.ts). Re-parsing the bytes
        // validateEntry blessed makes columns and bytes agree by
        // construction; validateEntry guarantees the §7 shape and types.
        const entry = JSON.parse(
          new TextDecoder().decode(validated.canonicalBytes),
        ) as Record<string, unknown>;
        if (entry["log_id"] !== logId) {
          throw new StoreError("log_mismatch", {
            entryId: entry["entry_id"],
            entryLogId: entry["log_id"],
            expectedLogId: logId,
          });
        }
        batch.push({
          entryId: String(entry["entry_id"]),
          writerId: String(entry["writer_id"]),
          writerSeq: Number(entry["writer_seq"]),
          prevEntryId: entry["prev_entry_id"] === null ? null : String(entry["prev_entry_id"]),
          createdAt: String(entry["created_at"]),
          canonicalBytes: validated.canonicalBytes,
        });
      }

      // §12.1 step 3: load the affected writers' tips from SQLite truth.
      const tips = new Map<string, TipInfo>();
      for (const writerId of new Set(batch.map((e) => e.writerId))) {
        const rows = this.sql
          .exec(
            "SELECT last_seq, last_entry_id FROM writer_tips WHERE writer_id = ?",
            writerId,
          )
          .toArray();
        const tip = rows[0];
        if (tip !== undefined) {
          tips.set(writerId, {
            seq: Number(tip.last_seq),
            entryId: String(tip.last_entry_id),
          });
        }
      }

      // §12.1 steps 2, 4, 5 live in the pure classifier: intra-batch
      // duplicate/coordinate detection, present-entry byte comparison
      // (backed by direct SQL lookups below), and suffix + predecessor-link
      // validation. An error outcome refuses the WHOLE batch.
      const outcome = planMerge(
        batch,
        tips,
        (writerId, writerSeq) => {
          const rows = this.sql
            .exec(
              "SELECT canonical_json FROM entries WHERE writer_id = ? AND writer_seq = ?",
              writerId,
              writerSeq,
            )
            .toArray();
          const row = rows[0];
          return row === undefined
            ? null
            : new Uint8Array(row.canonical_json as ArrayBuffer);
        },
        (entryId) => {
          const rows = this.sql
            .exec(
              "SELECT writer_id, writer_seq, canonical_json FROM entries WHERE entry_id = ?",
              entryId,
            )
            .toArray();
          const row = rows[0];
          return row === undefined
            ? null
            : {
                writerId: String(row.writer_id),
                writerSeq: Number(row.writer_seq),
                bytes: new Uint8Array(row.canonical_json as ArrayBuffer),
              };
        },
      );
      if (!outcome.ok) {
        // Recorded decision (merge-plan.ts): the internal invalid_batch code
        // surfaces as invalid_entry — the batch is malformed as submitted.
        throw new StoreError(
          outcome.code === "invalid_batch" ? "invalid_entry" : outcome.code,
          outcome.details,
        );
      }

      // §12.1 steps 6 + 7: insert every new entry (writers in writerId
      // order, entries in writer_seq order — the plan is already sorted
      // both ways), then advance each affected writer's tip to its last new
      // entry, all inside this same transaction.
      const receivedAtMs = Date.now();
      let inserted = 0;
      for (const plan of outcome.perWriter) {
        for (const entry of plan.newEntries as MergeBatchEntry[]) {
          this.sql.exec(
            `INSERT INTO entries
               (entry_id, writer_id, writer_seq, prev_entry_id, created_at,
                canonical_json, received_at_ms)
             VALUES (?, ?, ?, ?, ?, ?, ?)`,
            entry.entryId,
            entry.writerId,
            entry.writerSeq,
            entry.prevEntryId,
            entry.createdAt,
            toArrayBuffer(entry.canonicalBytes),
            receivedAtMs,
          );
          inserted++;
        }
        const last = plan.newEntries[plan.newEntries.length - 1]!;
        this.sql.exec(
          `INSERT INTO writer_tips (writer_id, last_seq, last_entry_id)
           VALUES (?, ?, ?)
           ON CONFLICT (writer_id) DO UPDATE
             SET last_seq = excluded.last_seq,
                 last_entry_id = excluded.last_entry_id`,
          plan.writerId,
          last.writerSeq,
          last.entryId,
        );
      }

      // §11.2 response: the post-merge frontier over ALL known writers,
      // sorted by writer_id (§9.4), read back from SQLite truth via the
      // SINGLE frontier query (readFrontier — shared with frontier()).
      return { inserted, present: outcome.presentCount, frontier: this.readFrontier() };
    });
  }

  /**
   * §9.4: one tip per known writer, sorted by writer_id; writers with no
   * entries are omitted (they have no writer_tips row). Reads committed
   * SQLite state directly — no cache, no transaction needed (single
   * statement, atomic in the DO). Throws log_not_found before createLog.
   */
  frontier(): FrontierEntry[] {
    if (this.readLogId() === null) {
      throw new StoreError("log_not_found", {});
    }
    return this.readFrontier();
  }

  /**
   * §9.5: one writer's canonical entries in ascending writer_seq, EXCLUSIVE
   * of afterSeq, INCLUSIVE of throughSeq (null = through the writer's tip;
   * beyond-tip values clamp to the tip). The store's merge/append invariants
   * guarantee the returned page is a complete contiguous range; nextAfterSeq
   * is the last returned seq when more of the (clamped) range remains, else
   * null.
   *
   * An unknown writerId yields empty entries and a null cursor, NOT an
   * error: §10 sync legitimately probes writers this replica has never seen.
   *
   * Caller-contract violations (negative/non-integer afterSeq or throughSeq,
   * limit < 1) throw a plain RangeError — the HTTP layer owns 4xx mapping
   * for malformed protocol input; StoreError codes are reserved for §11.6
   * log/entry semantics.
   */
  readWriter(
    writerId: string,
    afterSeq: number,
    throughSeq: number | null,
    limit: number,
  ): ReadWriterResult {
    if (!Number.isInteger(afterSeq) || afterSeq < 0) {
      throw new RangeError(`afterSeq must be a non-negative integer, got ${afterSeq}`);
    }
    if (throughSeq !== null && (!Number.isInteger(throughSeq) || throughSeq < 0)) {
      throw new RangeError(`throughSeq must be null or a non-negative integer, got ${throughSeq}`);
    }
    if (!Number.isInteger(limit) || limit < 1) {
      throw new RangeError(`limit must be a positive integer, got ${limit}`);
    }
    if (this.readLogId() === null) {
      throw new StoreError("log_not_found", {});
    }

    const tipRows = this.sql
      .exec("SELECT last_seq FROM writer_tips WHERE writer_id = ?", writerId)
      .toArray();
    const tipRow = tipRows[0];
    if (tipRow === undefined) {
      return { entries: [], nextAfterSeq: null };
    }
    const tip = Number(tipRow.last_seq);
    const through = throughSeq === null ? tip : Math.min(throughSeq, tip);
    if (through <= afterSeq) {
      return { entries: [], nextAfterSeq: null };
    }

    const entries = this.sql
      .exec(
        `SELECT canonical_json, writer_seq FROM entries
         WHERE writer_id = ? AND writer_seq > ? AND writer_seq <= ?
         ORDER BY writer_seq ASC LIMIT ?`,
        writerId,
        afterSeq,
        through,
        limit,
      )
      .toArray()
      .map((row) => ({
        canonicalBytes: new Uint8Array(row.canonical_json as ArrayBuffer),
        writerSeq: Number(row.writer_seq),
      }));

    const last = entries.length === 0 ? null : entries[entries.length - 1]!.writerSeq;
    return {
      entries,
      nextAfterSeq: last !== null && last < through ? last : null,
    };
  }

  /**
   * §9.6: entries in THIS replica's arrival order (§4). The cursor and order
   * are replica-local — for projectors, subscribers, and debugging only —
   * and MUST NOT be used for synchronization or equality (§9.6); sync uses
   * frontier() + readWriter(). Caller-contract violations throw RangeError
   * (see readWriter).
   */
  tailLocal(afterArrival: number, limit: number): TailResult {
    if (!Number.isInteger(afterArrival) || afterArrival < 0) {
      throw new RangeError(`afterArrival must be a non-negative integer, got ${afterArrival}`);
    }
    if (!Number.isInteger(limit) || limit < 1) {
      throw new RangeError(`limit must be a positive integer, got ${limit}`);
    }
    if (this.readLogId() === null) {
      throw new StoreError("log_not_found", {});
    }

    // Fetch limit+1 rows: the extra row (if any) only proves more remain —
    // arrival_seq contiguity is never assumed (rollbacks may burn ids).
    const rows = this.sql
      .exec(
        `SELECT canonical_json, arrival_seq FROM entries
         WHERE arrival_seq > ? ORDER BY arrival_seq ASC LIMIT ?`,
        afterArrival,
        limit + 1,
      )
      .toArray()
      .map((row) => ({
        canonicalBytes: new Uint8Array(row.canonical_json as ArrayBuffer),
        arrivalSeq: Number(row.arrival_seq),
      }));

    const more = rows.length > limit;
    const entries = more ? rows.slice(0, limit) : rows;
    return {
      entries,
      nextAfterArrival: more ? entries[entries.length - 1]!.arrivalSeq : null,
    };
  }

  /**
   * The ONE place the frontier SQL lives: ALL known writers' tips, sorted by
   * writer_id (§9.4). Used by both frontier() and mergeEntries().
   */
  private readFrontier(): FrontierEntry[] {
    return this.sql
      .exec(
        "SELECT writer_id, last_seq, last_entry_id FROM writer_tips ORDER BY writer_id",
      )
      .toArray()
      .map((row) => ({
        writerId: String(row.writer_id),
        seq: Number(row.last_seq),
        entryId: String(row.last_entry_id),
      }));
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
