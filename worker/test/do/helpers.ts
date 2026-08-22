/**
 * SP2 Task 8 shared test machinery: entry-chain factories, the multi-replica
 * access helpers (each named replica is a REAL Durable Object with its own
 * real SQLite storage under @cloudflare/vitest-pool-workers), the §10 sync
 * driver, the HTTP driver, and — most importantly — the AUDIT.
 *
 * The audit re-proves the §8 invariants from stored SQLite state alone,
 * trusting nothing the store reported:
 *   - per writer: COUNT(*) == MAX(writer_seq) == writer_tips.last_seq, and
 *     MIN(writer_seq) == 1 (complete prefix, invariant 5) with the tip's
 *     last_entry_id owned by the entry actually stored at last_seq;
 *   - entry 1's prev_entry_id is null; entry n>1 names entry n-1 (inv 6/7);
 *   - every row's columns match the fields inside its OWN canonical_json,
 *     and the bytes' log_id matches log_meta (inv 8, 11 — local metadata
 *     aside, the bytes are the entry).
 *
 * It returns a violations list (never asserts silently); expectAuditClean
 * asserts the list is empty so a failure prints every violation in full.
 * conformance.test.ts demonstrates the audit CAN fail via a trigger-legal
 * direct INSERT (the immutability triggers guard UPDATE/DELETE only).
 *
 * Chain factories are duplicated from merge.test.ts/http.test.ts by design:
 * the plan allows duplicating a small builder over churning reviewed files.
 */
import { env, runInDurableObject } from "cloudflare:test";
import { expect } from "vitest";
import { handleRequest } from "../../src/do/http";
import { LogStore, StoreError, type FrontierEntry } from "../../src/do/store";
import { uuidv7 } from "../../src/do/uuid";

export const LOG_ID = "0198cc6e-47ac-7d72-93db-b6fbd92bfca2";
export const CREATED_AT = "2026-08-22T12:00:00Z";

// Writer ids with a KNOWN lexicographic order (low < mid < high) so
// frontier-order assertions stay non-vacuous.
export const W_LOW = "0b7bc7de-92ee-4d63-9d1c-8b7f0f3a2c11";
export const W_MID = "7c1d2e3f-4a5b-4c6d-8e7f-901234567890";
export const W_HIGH = "fab4e8a5-ce9e-48d0-8f78-1d312b978207";

export type RawEntry = Record<string, unknown>;

export interface ChainOptions {
  logId?: string;
  bodyFor?: (seq: number) => Record<string, unknown>;
  createdAtFor?: (seq: number) => string;
}

/** n further valid entries for a writer, continuing after (lastSeq, lastEntryId). */
export function extendChain(
  writerId: string,
  n: number,
  lastSeq: number,
  lastEntryId: string | null,
  options: ChainOptions = {},
): RawEntry[] {
  const {
    logId = LOG_ID,
    bodyFor = (seq: number) => ({ writer: writerId, seq }),
    createdAtFor = () => CREATED_AT,
  } = options;
  const entries: RawEntry[] = [];
  let prev = lastEntryId;
  for (let i = 1; i <= n; i++) {
    const seq = lastSeq + i;
    const entryId = uuidv7();
    entries.push({
      version: 1,
      log_id: logId,
      entry_id: entryId,
      writer_id: writerId,
      writer_seq: seq,
      prev_entry_id: prev,
      created_at: createdAtFor(seq),
      body: bodyFor(seq),
    });
    prev = entryId;
  }
  return entries;
}

/** Chain of n valid entries for one writer starting at seq 1 (prevs linked). */
export function makeChain(
  writerId: string,
  n: number,
  options: ChainOptions = {},
): RawEntry[] {
  return extendChain(writerId, n, 0, null, options);
}

// ---------------------------------------------------------------------------
// The audit

export interface AuditViolation {
  rule: string;
  detail: string;
}

/**
 * Re-prove the stored state from SQLite alone. Returns every violation found
 * (empty list = clean). See the module comment for the rules.
 */
export function auditStore(sql: SqlStorage): AuditViolation[] {
  const violations: AuditViolation[] = [];
  const push = (rule: string, detail: string) => violations.push({ rule, detail });

  let logId: string | null = null;
  try {
    const meta = sql.exec("SELECT log_id FROM log_meta WHERE singleton = 1").toArray();
    logId = meta[0] === undefined ? null : String(meta[0].log_id);
  } catch {
    // Schema absent: fall through to the log-meta violation below.
  }
  if (logId === null) {
    push("log-meta", "log_meta has no singleton row (store uncreated)");
  }

  // Per-writer prefix + tip agreement.
  const perWriter = sql
    .exec(
      `SELECT writer_id, COUNT(*) AS n, MIN(writer_seq) AS min_seq,
              MAX(writer_seq) AS max_seq
       FROM entries GROUP BY writer_id ORDER BY writer_id`,
    )
    .toArray();
  const tips = new Map(
    sql
      .exec("SELECT writer_id, last_seq, last_entry_id FROM writer_tips")
      .toArray()
      .map((r) => [
        String(r.writer_id),
        { lastSeq: Number(r.last_seq), lastEntryId: String(r.last_entry_id) },
      ]),
  );
  const writersWithEntries = new Set<string>();
  for (const row of perWriter) {
    const w = String(row.writer_id);
    writersWithEntries.add(w);
    const n = Number(row.n);
    const min = Number(row.min_seq);
    const max = Number(row.max_seq);
    if (min !== 1) {
      push("prefix-starts-at-1", `writer ${w}: MIN(writer_seq) = ${min}, expected 1`);
    }
    if (n !== max) {
      push(
        "prefix-complete",
        `writer ${w}: COUNT(*) = ${n} but MAX(writer_seq) = ${max} (gap in the prefix)`,
      );
    }
    const tip = tips.get(w);
    if (tip === undefined) {
      push("tip-missing", `writer ${w}: has entries but no writer_tips row`);
    } else {
      if (tip.lastSeq !== max) {
        push(
          "tip-seq",
          `writer ${w}: writer_tips.last_seq = ${tip.lastSeq} but MAX(writer_seq) = ${max}`,
        );
      }
      const tipEntry = sql
        .exec(
          "SELECT entry_id FROM entries WHERE writer_id = ? AND writer_seq = ?",
          w,
          tip.lastSeq,
        )
        .toArray()[0];
      if (tipEntry === undefined) {
        push("tip-entry", `writer ${w}: no entry stored at last_seq ${tip.lastSeq}`);
      } else if (String(tipEntry.entry_id) !== tip.lastEntryId) {
        push(
          "tip-entry-id",
          `writer ${w}: writer_tips.last_entry_id = ${tip.lastEntryId} but the ` +
            `entry at seq ${tip.lastSeq} is ${String(tipEntry.entry_id)}`,
        );
      }
    }
  }
  for (const w of tips.keys()) {
    if (!writersWithEntries.has(w)) {
      push("tip-orphan", `writer ${w}: writer_tips row but no entries`);
    }
  }

  // Chain links + column<->canonical_json agreement, one ordered walk.
  const rows = sql
    .exec(
      `SELECT entry_id, writer_id, writer_seq, prev_entry_id, created_at,
              canonical_json
       FROM entries ORDER BY writer_id, writer_seq`,
    )
    .toArray();
  let prevRow: { writerId: string; seq: number; entryId: string } | null = null;
  for (const r of rows) {
    const w = String(r.writer_id);
    const seq = Number(r.writer_seq);
    const entryId = String(r.entry_id);
    const prev = r.prev_entry_id === null ? null : String(r.prev_entry_id);
    const sameWriter = prevRow !== null && prevRow.writerId === w;

    if (seq === 1) {
      if (prev !== null) {
        push("first-prev-null", `writer ${w} seq 1: prev_entry_id = ${prev}, expected null`);
      }
    } else if (!sameWriter) {
      push("chain-start", `writer ${w}: first stored row is seq ${seq}; seq ${seq - 1} is missing`);
    } else if (prevRow!.seq !== seq - 1) {
      push("sequence-gap", `writer ${w}: writer_seq jumps from ${prevRow!.seq} to ${seq}`);
    } else if (prev !== prevRow!.entryId) {
      push(
        "chain-link",
        `writer ${w} seq ${seq}: prev_entry_id = ${prev} but entry ${seq - 1} ` +
          `is ${prevRow!.entryId}`,
      );
    }

    let parsed: Record<string, unknown> | null = null;
    try {
      parsed = JSON.parse(
        new TextDecoder().decode(new Uint8Array(r.canonical_json as ArrayBuffer)),
      ) as Record<string, unknown>;
    } catch {
      push("bytes-unparsable", `writer ${w} seq ${seq}: canonical_json is not valid JSON`);
    }
    if (parsed !== null) {
      const fields: Array<[string, unknown, unknown]> = [
        ["entry_id", entryId, parsed["entry_id"]],
        ["writer_id", w, parsed["writer_id"]],
        ["writer_seq", seq, parsed["writer_seq"]],
        ["prev_entry_id", prev, parsed["prev_entry_id"] ?? null],
        ["created_at", String(r.created_at), parsed["created_at"]],
      ];
      for (const [field, column, inBytes] of fields) {
        if (column !== inBytes) {
          push(
            "column-bytes",
            `writer ${w} seq ${seq}: column ${field} = ${JSON.stringify(column)} ` +
              `but its own canonical_json says ${JSON.stringify(inBytes)}`,
          );
        }
      }
      if (logId !== null && parsed["log_id"] !== logId) {
        push(
          "bytes-log-id",
          `writer ${w} seq ${seq}: canonical_json log_id = ` +
            `${JSON.stringify(parsed["log_id"])} but log_meta says ${logId}`,
        );
      }
    }
    prevRow = { writerId: w, seq, entryId };
  }

  return violations;
}

/** Assert the audit is clean; a failure prints EVERY violation in full. */
export function expectAuditClean(sql: SqlStorage): void {
  expect(auditStore(sql)).toEqual([]);
}

// ---------------------------------------------------------------------------
// Replica access: each name addresses a real Durable Object whose real
// SQLite storage is isolated per test by the workers pool.

export interface ReplicaCtx {
  sql: SqlStorage;
  store: LogStore;
  state: DurableObjectState;
}

export function replicaStub(name: string) {
  return env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName(name));
}

/**
 * Run `fn` inside the named replica's Durable Object with a LogStore over its
 * real SqlStorage + transactionSync. The return value crosses the
 * runInDurableObject boundary and must be structured-clonable (plain data —
 * never a Response or a class instance).
 */
export async function onReplica<T>(
  name: string,
  fn: (ctx: ReplicaCtx) => T | Promise<T>,
): Promise<T> {
  return await runInDurableObject(replicaStub(name), (_instance, state) => {
    const store = new LogStore(state.storage.sql, state.storage);
    return fn({ sql: state.storage.sql, store, state });
  });
}

export async function createReplica(name: string, logId = LOG_ID): Promise<void> {
  await onReplica(name, ({ store }) => store.createLog(logId));
}

export async function mergeInto(
  name: string,
  entries: RawEntry[],
): Promise<{ inserted: number; present: number }> {
  return await onReplica(name, ({ store }) => {
    const result = store.mergeEntries(entries);
    return { inserted: result.inserted, present: result.present };
  });
}

/** Merge expected to FAIL: returns the StoreError's code + details. */
export async function mergeErrorInto(
  name: string,
  entries: RawEntry[],
): Promise<{ code: string; details: unknown } | null> {
  return await onReplica(name, ({ store }) => {
    try {
      store.mergeEntries(entries);
      return null;
    } catch (error) {
      if (error instanceof StoreError) {
        return { code: error.code, details: error.details };
      }
      throw error;
    }
  });
}

/** Append via the store API; returns the produced entry as a plain object. */
export async function appendOn(
  name: string,
  writerId: string,
  body: Record<string, unknown>,
  createdAt = CREATED_AT,
): Promise<RawEntry> {
  return await onReplica(name, ({ store }) => {
    const result = store.append(writerId, body, createdAt);
    return JSON.parse(
      new TextDecoder().decode(result.entry.canonicalBytes),
    ) as RawEntry;
  });
}

export async function frontierOf(name: string): Promise<FrontierEntry[]> {
  return await onReplica(name, ({ store }) => store.frontier());
}

export function toHex(bytes: Uint8Array): string {
  let out = "";
  for (const b of bytes) out += b.toString(16).padStart(2, "0");
  return out;
}

/**
 * The replica's canonical byte SET: every stored entry's exact canonical
 * bytes, hex-encoded (a faithful, order-preserving byte representation),
 * sorted for set comparison. Equality of two of these lists IS byte-set
 * equality of the two entries tables.
 */
export async function entryByteSetOf(name: string): Promise<string[]> {
  return await onReplica(name, ({ sql }) =>
    sql
      .exec("SELECT canonical_json FROM entries")
      .toArray()
      .map((r) => toHex(new Uint8Array(r.canonical_json as ArrayBuffer)))
      .sort(),
  );
}

/** entry_ids in THIS replica's local arrival order (§9.6 semantics). */
export async function arrivalOrderOf(name: string): Promise<string[]> {
  return await onReplica(name, ({ sql }) =>
    sql
      .exec("SELECT entry_id FROM entries ORDER BY arrival_seq")
      .toArray()
      .map((r) => String(r.entry_id)),
  );
}

export async function auditReplica(name: string): Promise<AuditViolation[]> {
  return await onReplica(name, ({ sql }) => auditStore(sql));
}

export async function expectReplicaAuditClean(...names: string[]): Promise<void> {
  for (const name of names) {
    expect(await auditReplica(name), `audit of replica ${name}`).toEqual([]);
  }
}

/** One §9.5 page as parsed canonical entry objects plus its last seq. */
export async function readWriterPage(
  name: string,
  writerId: string,
  afterSeq: number,
  throughSeq: number | null,
  limit: number,
): Promise<{ entries: RawEntry[]; lastSeq: number | null }> {
  return await onReplica(name, ({ store }) => {
    const page = store.readWriter(writerId, afterSeq, throughSeq, limit);
    const entries = page.entries.map(
      (e) => JSON.parse(new TextDecoder().decode(e.canonicalBytes)) as RawEntry,
    );
    const last = page.entries[page.entries.length - 1];
    return { entries, lastSeq: last === undefined ? null : last.writerSeq };
  });
}

/**
 * §10 one-direction sync: bring `to` up to `from`'s snapshot frontier using
 * frontier + read_writer + merge, page by page. Returns the number of pages
 * merged. Equal-seq tips with different entry ids are a writer fork (§10
 * step 3) and throw.
 */
export async function syncOneDirection(
  from: string,
  to: string,
  pageLimit: number,
): Promise<number> {
  const remote = await frontierOf(from);
  const local = await frontierOf(to);
  let pages = 0;
  for (const remoteTip of remote) {
    const localTip = local.find((t) => t.writerId === remoteTip.writerId);
    const localSeq = localTip?.seq ?? 0;
    if (
      localTip !== undefined &&
      localTip.seq === remoteTip.seq &&
      localTip.entryId !== remoteTip.entryId
    ) {
      throw new Error(`writer_fork during sync: writer ${remoteTip.writerId}`);
    }
    let cursor = localSeq;
    while (cursor < remoteTip.seq) {
      const page = await readWriterPage(
        from,
        remoteTip.writerId,
        cursor,
        remoteTip.seq,
        pageLimit,
      );
      if (page.entries.length === 0 || page.lastSeq === null) {
        throw new Error(
          `sync page unexpectedly empty: writer ${remoteTip.writerId} after ${cursor}`,
        );
      }
      await mergeInto(to, page.entries);
      pages++;
      cursor = page.lastSeq;
    }
  }
  return pages;
}

// ---------------------------------------------------------------------------
// HTTP driver (same shape as http.test.ts's, shared here for conformance)

/** A Response flattened to structured-clonable data: a Response object must
 * not cross the runInDurableObject boundary. */
export interface Wire {
  status: number;
  contentType: string | null;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  body: any;
}

/**
 * Drive one §11 request through handleRequest over the named replica's real
 * storage. objectName is the replica name, mimicking production ctx.id.name
 * for a log DO addressed via idFromName (see http.test.ts's harness note).
 */
export async function httpOn(
  replicaName: string,
  method: string,
  path: string,
  reqBody?: unknown,
): Promise<Wire> {
  return await runInDurableObject(replicaStub(replicaName), async (_instance, state) => {
    const init: RequestInit = { method };
    if (reqBody !== undefined) {
      init.body = typeof reqBody === "string" ? reqBody : JSON.stringify(reqBody);
    }
    const store = new LogStore(state.storage.sql, state.storage);
    const res = await handleRequest(new Request(`https://do${path}`, init), {
      store,
      objectName: replicaName,
    });
    return {
      status: res.status,
      contentType: res.headers.get("content-type"),
      body: await res.json(),
    };
  });
}
