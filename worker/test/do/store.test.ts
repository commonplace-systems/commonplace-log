import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { validateEntry } from "../../src/entry";
import { LogStore, StoreError } from "../../src/do/store";
import { uuidv7 } from "../../src/do/uuid";

/**
 * SP2 Task 4: LogStore.createLog + append over real DO SQLite (§9.1, §9.2).
 *
 * Every assertion is verified by effect against the actual SQLite state, and
 * canonical bytes are compared against SP1's validateEntry/canonicalize — the
 * store's own encoding is never trusted as its own oracle.
 *
 * Anti-vacuity: this file registers 20 tests (>= the 12-test floor).
 */

const LOG_ID = "0198cc6e-47ac-7d72-93db-b6fbd92bfca2";
const OTHER_LOG_ID = "0198cc6e-47ac-7d72-93db-b6fbd92bfca3";
const WRITER_A = "fab4e8a5-ce9e-48d0-8f78-1d312b978207";
const WRITER_B = "0b7bc7de-92ee-4d63-9d1c-8b7f0f3a2c11";
const CREATED_AT = "2026-08-22T12:00:00Z";

const UUIDV7_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;

interface StoreCtx {
  sql: SqlStorage;
  store: LogStore;
  /** Fresh LogStore instance over the SAME sql handle (durability tests). */
  makeStore: () => LogStore;
  /** LogStore over a WRAPPED sql handle but the real transactionSync (fault injection). */
  makeStoreWith: (sql: SqlStorage) => LogStore;
}

/** Run `fn` with a LogStore over a fresh Durable Object's real SQLite storage. */
async function withStore<T>(fn: (ctx: StoreCtx) => T): Promise<T> {
  const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName("store-test"));
  return await runInDurableObject(stub, (_instance, state) => {
    const makeStoreWith = (sql: SqlStorage) => new LogStore(sql, state.storage);
    const makeStore = () => makeStoreWith(state.storage.sql);
    return fn({ sql: state.storage.sql, store: makeStore(), makeStore, makeStoreWith });
  });
}

function count(sql: SqlStorage, table: string): number {
  return Number(sql.exec(`SELECT COUNT(*) AS n FROM ${table}`).one().n);
}

function catchError(fn: () => unknown): unknown {
  try {
    fn();
  } catch (error) {
    return error;
  }
  return undefined;
}

describe("createLog (§9.1)", () => {
  it("creates the log_meta singleton row with the log_id and format_version 1", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const rows = sql.exec("SELECT * FROM log_meta").toArray();
      expect(rows).toHaveLength(1);
      expect(rows[0]!.singleton).toBe(1);
      expect(rows[0]!.log_id).toBe(LOG_ID);
      expect(rows[0]!.format_version).toBe(1);
      expect(typeof rows[0]!.created_at).toBe("string");
    });
  });

  it("is idempotent: calling twice with the same log_id leaves exactly one row", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      expect(() => store.createLog(LOG_ID)).not.toThrow();
      expect(count(sql, "log_meta")).toBe(1);
      expect(sql.exec("SELECT log_id FROM log_meta").one().log_id).toBe(LOG_ID);
    });
  });

  it("rejects a DIFFERENT log_id on the same instance with log_mismatch", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const error = catchError(() => store.createLog(OTHER_LOG_ID));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("log_mismatch");
      // The stored identity is untouched.
      expect(count(sql, "log_meta")).toBe(1);
      expect(sql.exec("SELECT log_id FROM log_meta").one().log_id).toBe(LOG_ID);
    });
  });

  it("rejects reuse of the physical store by a FRESH instance with a different log_id", async () => {
    await withStore(({ sql, store, makeStore }) => {
      store.createLog(LOG_ID);
      // §9.1: reusing a physical store for a different log_id MUST fail —
      // a new LogStore instance over the same SQLite is the same physical store.
      const second = makeStore();
      const error = catchError(() => second.createLog(OTHER_LOG_ID));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("log_mismatch");
      expect(sql.exec("SELECT log_id FROM log_meta").one().log_id).toBe(LOG_ID);
    });
  });
});

describe("append (§9.2)", () => {
  it("before createLog fails with log_not_found", async () => {
    await withStore(({ store }) => {
      const error = catchError(() => store.append(WRITER_A, { a: 1 }, CREATED_AT));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("log_not_found");
    });
  });

  it("first append allocates writer_seq 1 with null prev_entry_id", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const result = store.append(WRITER_A, { hello: "world" }, CREATED_AT);

      expect(result.entry.writerSeq).toBe(1);
      expect(result.entry.prevEntryId).toBeNull();
      expect(result.entry.writerId).toBe(WRITER_A);
      expect(result.entry.logId).toBe(LOG_ID);
      expect(result.entry.createdAt).toBe(CREATED_AT);
      expect(result.arrivalSeq).toBe(1);

      const row = sql.exec("SELECT * FROM entries").one();
      expect(row.entry_id).toBe(result.entry.entryId);
      expect(row.writer_id).toBe(WRITER_A);
      expect(row.writer_seq).toBe(1);
      expect(row.prev_entry_id).toBeNull();
      expect(row.created_at).toBe(CREATED_AT);
      expect(typeof row.received_at_ms).toBe("number");
    });
  });

  it("stores EXACTLY the canonical bytes of the entry (byte-compare vs SP1's canonicalizer)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const body = { hello: "world", n: 1, nested: { z: [1, 2, 3], a: true } };
      const result = store.append(WRITER_A, body, CREATED_AT);

      // Independently construct the same entry from the returned identity and
      // run it through SP1's validator/canonicalizer — the arbiter of bytes.
      const expected = {
        version: 1,
        log_id: LOG_ID,
        entry_id: result.entry.entryId,
        writer_id: WRITER_A,
        writer_seq: 1,
        prev_entry_id: null,
        created_at: CREATED_AT,
        body,
      };
      const validated = validateEntry(
        new TextEncoder().encode(JSON.stringify(expected)),
      );
      expect(validated.ok).toBe(true);
      if (!validated.ok) throw new Error("unreachable");

      const stored = sql
        .exec("SELECT canonical_json FROM entries WHERE entry_id = ?", result.entry.entryId)
        .one();
      const storedBytes = new Uint8Array(stored.canonical_json as ArrayBuffer);
      expect(storedBytes.byteLength).toBe(validated.canonicalBytes.byteLength);
      expect(Array.from(storedBytes)).toEqual(Array.from(validated.canonicalBytes));
    });
  });

  it("chains: three appends get seqs 1,2,3 each naming its predecessor; writer_tips matches", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const r1 = store.append(WRITER_A, { i: 1 }, CREATED_AT);
      const r2 = store.append(WRITER_A, { i: 2 }, CREATED_AT);
      const r3 = store.append(WRITER_A, { i: 3 }, CREATED_AT);

      expect([r1.entry.writerSeq, r2.entry.writerSeq, r3.entry.writerSeq]).toEqual([1, 2, 3]);
      expect(r1.entry.prevEntryId).toBeNull();
      expect(r2.entry.prevEntryId).toBe(r1.entry.entryId);
      expect(r3.entry.prevEntryId).toBe(r2.entry.entryId);

      // Verify by effect from stored rows, not just returned values.
      const rows = sql
        .exec("SELECT entry_id, writer_seq, prev_entry_id FROM entries ORDER BY writer_seq")
        .toArray();
      expect(rows).toHaveLength(3);
      expect(rows[0]!.prev_entry_id).toBeNull();
      expect(rows[1]!.prev_entry_id).toBe(rows[0]!.entry_id);
      expect(rows[2]!.prev_entry_id).toBe(rows[1]!.entry_id);

      const tips = sql.exec("SELECT * FROM writer_tips").toArray();
      expect(tips).toHaveLength(1);
      expect(tips[0]!.writer_id).toBe(WRITER_A);
      expect(tips[0]!.last_seq).toBe(3);
      expect(tips[0]!.last_entry_id).toBe(r3.entry.entryId);
    });
  });

  it("two interleaved writers get independent sequences and independent tips", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const a1 = store.append(WRITER_A, { w: "a" }, CREATED_AT);
      const b1 = store.append(WRITER_B, { w: "b" }, CREATED_AT);
      const a2 = store.append(WRITER_A, { w: "a" }, CREATED_AT);
      const b2 = store.append(WRITER_B, { w: "b" }, CREATED_AT);

      expect([a1.entry.writerSeq, a2.entry.writerSeq]).toEqual([1, 2]);
      expect([b1.entry.writerSeq, b2.entry.writerSeq]).toEqual([1, 2]);
      expect(a2.entry.prevEntryId).toBe(a1.entry.entryId);
      expect(b2.entry.prevEntryId).toBe(b1.entry.entryId);

      const tips = sql.exec("SELECT * FROM writer_tips ORDER BY writer_id").toArray();
      expect(tips).toHaveLength(2);
      const byWriter = new Map(tips.map((t) => [t.writer_id, t]));
      expect(byWriter.get(WRITER_A)!.last_seq).toBe(2);
      expect(byWriter.get(WRITER_A)!.last_entry_id).toBe(a2.entry.entryId);
      expect(byWriter.get(WRITER_B)!.last_seq).toBe(2);
      expect(byWriter.get(WRITER_B)!.last_entry_id).toBe(b2.entry.entryId);
    });
  });

  it("assigns strictly increasing arrival_seq across writers (local metadata)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const results = [
        store.append(WRITER_A, { i: 1 }, CREATED_AT),
        store.append(WRITER_B, { i: 2 }, CREATED_AT),
        store.append(WRITER_A, { i: 3 }, CREATED_AT),
        store.append(WRITER_B, { i: 4 }, CREATED_AT),
        store.append(WRITER_A, { i: 5 }, CREATED_AT),
      ];
      const arrivals = results.map((r) => r.arrivalSeq);
      for (let i = 1; i < arrivals.length; i++) {
        expect(arrivals[i]!).toBeGreaterThan(arrivals[i - 1]!);
      }
      // And they are the actual arrival_seq column values.
      const stored = sql
        .exec("SELECT arrival_seq FROM entries ORDER BY arrival_seq")
        .toArray()
        .map((r) => Number(r.arrival_seq));
      expect(stored).toEqual(arrivals);
    });
  });

  it("generates canonical-form UUIDv7 entry_ids, unique across appends", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      const ids = [];
      for (let i = 0; i < 5; i++) {
        ids.push(store.append(WRITER_A, { i }, CREATED_AT).entry.entryId);
      }
      for (const id of ids) {
        expect(id).toMatch(UUIDV7_RE);
      }
      expect(new Set(ids).size).toBe(5);
    });
  });

  it("oversized body -> entry_too_large, and NOTHING was written (§8 invariant 10)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      // Establish state first so "unchanged" is a real claim, not vacuous.
      const first = store.append(WRITER_A, { ok: true }, CREATED_AT);
      expect(first.entry.writerSeq).toBe(1);

      const error = catchError(() =>
        store.append(WRITER_A, { pad: "x".repeat(1_048_576) }, CREATED_AT),
      );
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("entry_too_large");
      expect((error as StoreError).details).toMatchObject({
        reason: "canonical-bytes-over-1mib",
      });

      // Row counts and tips unchanged.
      expect(count(sql, "entries")).toBe(1);
      const tip = sql.exec("SELECT last_seq, last_entry_id FROM writer_tips").one();
      expect(tip.last_seq).toBe(1);
      expect(tip.last_entry_id).toBe(first.entry.entryId);

      // The writer chain is still healthy: the next append gets seq 2.
      const next = store.append(WRITER_A, { ok: 2 }, CREATED_AT);
      expect(next.entry.writerSeq).toBe(2);
      expect(next.entry.prevEntryId).toBe(first.entry.entryId);
    });
  });

  it("non-object body -> invalid_entry with SP1's slug in details, nothing written", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const error = catchError(() =>
        store.append(WRITER_A, "not an object", CREATED_AT),
      );
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("invalid_entry");
      expect((error as StoreError).details).toMatchObject({ reason: "body-not-object" });
      expect(count(sql, "entries")).toBe(0);
      expect(count(sql, "writer_tips")).toBe(0);
    });
  });

  it("unsafe integer in body -> invalid_entry (unsafe-integer), nothing written", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      // 2**53 is one past the I-JSON safe range; its canonical integer
      // literal must be rejected by SP1's lexical rule.
      const error = catchError(() =>
        store.append(WRITER_A, { n: 2 ** 53 }, CREATED_AT),
      );
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("invalid_entry");
      expect((error as StoreError).details).toMatchObject({ reason: "unsafe-integer" });
      expect(count(sql, "entries")).toBe(0);
      expect(count(sql, "writer_tips")).toBe(0);
    });
  });

  it("fault between the entries INSERT and the tip upsert rolls back the completed INSERT", async () => {
    await withStore(({ sql, store, makeStore, makeStoreWith }) => {
      store.createLog(LOG_ID);

      // Fault injection INSIDE the real transactionSync: the entries INSERT
      // succeeds, then the writer_tips upsert throws. Both review mutants
      // (tip-read hoisted out of the txn; transactor replaced with a
      // pass-through) survived the previous suite because every committed
      // error path threw BEFORE the first INSERT — this test is what makes
      // the transaction falsifiable: only a real rollback can erase a row
      // that was already inserted.
      const faultedSql = new Proxy(sql, {
        get(target, prop) {
          if (prop === "exec") {
            return (query: string, ...bindings: unknown[]) => {
              if (query.includes("INSERT INTO writer_tips")) {
                throw new Error("injected fault: writer_tips upsert");
              }
              return target.exec(query, ...bindings);
            };
          }
          const value = Reflect.get(target, prop, target);
          return typeof value === "function" ? value.bind(target) : value;
        },
      }) as SqlStorage;

      const faulted = makeStoreWith(faultedSql);
      const error = catchError(() => faulted.append(WRITER_A, { i: 1 }, CREATED_AT));

      // Positive control: the failure IS the injected fault — proof the
      // append got past validation and the entries INSERT before dying.
      expect(error).toBeInstanceOf(Error);
      expect((error as Error).message).toContain("injected fault: writer_tips upsert");

      // The completed entries INSERT genuinely rolled back; no tip either.
      expect(count(sql, "entries")).toBe(0);
      expect(count(sql, "writer_tips")).toBe(0);

      // A subsequent clean append on an unwrapped store starts at seq 1.
      const clean = makeStore().append(WRITER_A, { i: 1 }, CREATED_AT);
      expect(clean.entry.writerSeq).toBe(1);
      expect(clean.entry.prevEntryId).toBeNull();
      expect(count(sql, "entries")).toBe(1);
    });
  });

  it("a SECOND LogStore instance over the same sql continues the sequence from SQLite truth", async () => {
    await withStore(({ sql, store, makeStore }) => {
      store.createLog(LOG_ID);
      const r1 = store.append(WRITER_A, { i: 1 }, CREATED_AT);
      expect(r1.entry.writerSeq).toBe(1);

      // No instance-local cache may be load-bearing (§15.2 analog): a fresh
      // instance must read the tip from SQLite and continue correctly.
      const second = makeStore();
      const r2 = second.append(WRITER_A, { i: 2 }, CREATED_AT);
      expect(r2.entry.writerSeq).toBe(2);
      expect(r2.entry.prevEntryId).toBe(r1.entry.entryId);

      const tip = sql.exec("SELECT last_seq, last_entry_id FROM writer_tips").one();
      expect(tip.last_seq).toBe(2);
      expect(tip.last_entry_id).toBe(r2.entry.entryId);
      expect(count(sql, "entries")).toBe(2);
    });
  });
});

describe("uuidv7 helper (RFC 9562 layout)", () => {
  it("produces canonical lowercase UUIDv7 strings (version nibble 7, variant 10xx)", () => {
    for (let i = 0; i < 20; i++) {
      expect(uuidv7()).toMatch(UUIDV7_RE);
    }
  });

  it("two calls differ (random bits are live)", () => {
    const a = uuidv7();
    const b = uuidv7();
    expect(a).not.toBe(b);
  });

  it("the 48-bit timestamp field is Date.now-based and monotone-or-equal across quick calls", () => {
    const tsOf = (id: string): number =>
      parseInt(id.slice(0, 8) + id.slice(9, 13), 16);
    const before = Date.now();
    const ids = Array.from({ length: 10 }, () => uuidv7());
    const after = Date.now();

    const stamps = ids.map(tsOf);
    for (let i = 1; i < stamps.length; i++) {
      expect(stamps[i]!).toBeGreaterThanOrEqual(stamps[i - 1]!);
    }
    for (const t of stamps) {
      expect(t).toBeGreaterThanOrEqual(before);
      expect(t).toBeLessThanOrEqual(after);
    }
  });

  it("embeds an explicitly provided millisecond timestamp exactly", () => {
    const id = uuidv7(0x0123456789ab);
    expect(id.slice(0, 8) + id.slice(9, 13)).toBe("0123456789ab");
  });
});
