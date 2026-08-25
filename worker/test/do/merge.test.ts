import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { validateEntry } from "../../src/entry";
import { LogStore, StoreError } from "../../src/do/store";
import { uuidv7 } from "../../src/do/uuid";

/**
 * SP2 Task 5: LogStore.mergeEntries — the §12.1 seven-step transactional
 * batch merge executing the pure §9.3 classifier's plan over real DO SQLite.
 *
 * Every assertion is verified by effect against actual SQLite state; stored
 * bytes are compared against SP1's validateEntry canonical bytes — the store
 * is never its own byte oracle.
 *
 * Anti-vacuity: this file registers 24 tests (>= the 14-test floor).
 */

const LOG_ID = "0198cc6e-47ac-7d72-93db-b6fbd92bfca2";
const OTHER_LOG_ID = "0198cc6e-47ac-7d72-93db-b6fbd92bfca3";
// Three writer ids with a KNOWN lexicographic order (low < mid < high) so
// frontier-sorting and mixed-writer-order assertions are non-vacuous.
const W_LOW = "0b7bc7de-92ee-4d63-9d1c-8b7f0f3a2c11";
const W_MID = "7c1d2e3f-4a5b-4c6d-8e7f-901234567890";
const W_HIGH = "fab4e8a5-ce9e-48d0-8f78-1d312b978207";
const CREATED_AT = "2026-08-22T12:00:00Z";

/** A raw version-1 entry object, as the future HTTP layer would hand over. */
type RawEntry = Record<string, unknown>;

interface StoreCtx {
  sql: SqlStorage;
  store: LogStore;
  makeStore: () => LogStore;
  /** LogStore over a WRAPPED sql handle but the real transactionSync (fault injection). */
  makeStoreWith: (sql: SqlStorage) => LogStore;
}

async function withStore<T>(fn: (ctx: StoreCtx) => T): Promise<T> {
  const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName("merge-test"));
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

/** Chain of n valid entries for one writer starting at seq 1 (prevs linked). */
function makeChain(writerId: string, n: number, logId = LOG_ID): RawEntry[] {
  return extendChain(writerId, n, 0, null, logId);
}

/** n further entries for a writer, continuing after (lastSeq, lastEntryId). */
function extendChain(
  writerId: string,
  n: number,
  lastSeq: number,
  lastEntryId: string | null,
  logId = LOG_ID,
): RawEntry[] {
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
      created_at: CREATED_AT,
      body: { writer: writerId, seq },
    });
    prev = entryId;
  }
  return entries;
}

/** SP1's canonical bytes for a raw entry — the independent byte oracle. */
function canonicalBytesOf(entry: RawEntry): Uint8Array {
  const validated = validateEntry(new TextEncoder().encode(JSON.stringify(entry)));
  if (!validated.ok) throw new Error(`fixture invalid: ${validated.reason}`);
  return validated.canonicalBytes;
}

function storedBytes(sql: SqlStorage, entryId: string): Uint8Array {
  const row = sql
    .exec("SELECT canonical_json FROM entries WHERE entry_id = ?", entryId)
    .one();
  return new Uint8Array(row.canonical_json as ArrayBuffer);
}

function tipsByWriter(sql: SqlStorage): Map<string, { seq: number; entryId: string }> {
  return new Map(
    sql
      .exec("SELECT writer_id, last_seq, last_entry_id FROM writer_tips")
      .toArray()
      .map((r) => [
        String(r.writer_id),
        { seq: Number(r.last_seq), entryId: String(r.last_entry_id) },
      ]),
  );
}

describe("mergeEntries (§12.1 / §9.3)", () => {
  it("before createLog fails with log_not_found", async () => {
    await withStore(({ store }) => {
      const error = catchError(() => store.mergeEntries(makeChain(W_LOW, 1)));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("log_not_found");
    });
  });

  it("fresh-writer batch inserts all entries with exact canonical bytes and correct frontier", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 3);
      const result = store.mergeEntries(chain);

      expect(result.inserted).toBe(3);
      expect(result.present).toBe(0);
      expect(result.frontier).toEqual([
        { writerId: W_LOW, seq: 3, entryId: chain[2]!.entry_id },
      ]);

      // Verify by effect: rows exist and hold EXACTLY SP1's canonical bytes.
      expect(count(sql, "entries")).toBe(3);
      for (const entry of chain) {
        const stored = storedBytes(sql, entry.entry_id as string);
        expect(Array.from(stored)).toEqual(Array.from(canonicalBytesOf(entry)));
      }
      const tips = tipsByWriter(sql);
      expect(tips.get(W_LOW)).toEqual({ seq: 3, entryId: chain[2]!.entry_id });

      // Arrival metadata assigned in writer_seq order for the writer.
      const arrivals = sql
        .exec(
          "SELECT arrival_seq FROM entries WHERE writer_id = ? ORDER BY writer_seq",
          W_LOW,
        )
        .toArray()
        .map((r) => Number(r.arrival_seq));
      expect(arrivals).toHaveLength(3);
      for (let i = 1; i < arrivals.length; i++) {
        expect(arrivals[i]!).toBeGreaterThan(arrivals[i - 1]!);
      }
    });
  });

  it("lanes may mix v1/v2 and operation_id is persisted but not uniqueness-enforced", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const mixedLane = makeChain(W_LOW, 2);
      const v1 = mixedLane[0]!;
      const secondV1 = mixedLane[1]!;
      const v2: RawEntry = {
        ...secondV1,
        version: 2,
        operation_id: "mixed-lane-operation",
      };
      const otherWriterV1 = makeChain(W_MID, 1)[0]!;
      const otherWriterV2: RawEntry = {
        ...otherWriterV1,
        version: 2,
        operation_id: "mixed-lane-operation",
      };

      expect(store.mergeEntries([v1, v2, otherWriterV2])).toMatchObject({
        inserted: 3,
        present: 0,
      });
      const stored = storedBytes(sql, String(v2["entry_id"]));
      expect(Array.from(stored)).toEqual(Array.from(canonicalBytesOf(v2)));
      const parsed = JSON.parse(new TextDecoder().decode(stored)) as Record<string, unknown>;
      expect(parsed["version"]).toBe(2);
      expect(parsed["operation_id"]).toBe("mixed-lane-operation");
      const otherParsed = JSON.parse(
        new TextDecoder().decode(storedBytes(sql, String(otherWriterV2["entry_id"]))),
      ) as Record<string, unknown>;
      expect(otherParsed["operation_id"]).toBe("mixed-lane-operation");
    });
  });

  it("frontier lists ALL writers sorted by writerId even when inserted out of order (§9.4)", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      const high = makeChain(W_HIGH, 2);
      const low = makeChain(W_LOW, 1);
      const mid = makeChain(W_MID, 3);
      // Batch deliberately ordered high, low, mid — not sorted.
      const result = store.mergeEntries([...high, ...low, ...mid]);

      expect(result.inserted).toBe(6);
      expect(result.frontier.map((f) => f.writerId)).toEqual([W_LOW, W_MID, W_HIGH]);
      expect(result.frontier).toEqual([
        { writerId: W_LOW, seq: 1, entryId: low[0]!.entry_id },
        { writerId: W_MID, seq: 3, entryId: mid[2]!.entry_id },
        { writerId: W_HIGH, seq: 2, entryId: high[1]!.entry_id },
      ]);
    });
  });

  it("extension batch continues an existing chain from tip+1", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 2);
      store.mergeEntries(chain);

      const ext = extendChain(W_LOW, 2, 2, chain[1]!.entry_id as string);
      const result = store.mergeEntries(ext);
      expect(result.inserted).toBe(2);
      expect(result.present).toBe(0);
      expect(result.frontier).toEqual([
        { writerId: W_LOW, seq: 4, entryId: ext[1]!.entry_id },
      ]);
      expect(count(sql, "entries")).toBe(4);
      expect(tipsByWriter(sql).get(W_LOW)).toEqual({
        seq: 4,
        entryId: ext[1]!.entry_id,
      });
    });
  });

  it("re-sending an identical batch is a no-op: inserted 0, present n, state unchanged (§8 inv 9)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 3);
      store.mergeEntries(chain);
      const before = tipsByWriter(sql);

      const result = store.mergeEntries(chain);
      expect(result.inserted).toBe(0);
      expect(result.present).toBe(3);
      expect(result.frontier).toEqual([
        { writerId: W_LOW, seq: 3, entryId: chain[2]!.entry_id },
      ]);
      expect(count(sql, "entries")).toBe(3);
      expect(tipsByWriter(sql)).toEqual(before);
    });
  });

  it("mixed present-prefix + new-suffix: inserted + present = batch size (§11.2 arithmetic)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 3);
      store.mergeEntries(chain);

      // Batch resends seqs 2–3 and adds seqs 4–5.
      const ext = extendChain(W_LOW, 2, 3, chain[2]!.entry_id as string);
      const batch = [chain[1]!, chain[2]!, ...ext];
      const result = store.mergeEntries(batch);

      expect(result.inserted).toBe(2);
      expect(result.present).toBe(2);
      expect(result.inserted + result.present).toBe(batch.length);
      expect(count(sql, "entries")).toBe(5);
      expect(tipsByWriter(sql).get(W_LOW)).toEqual({
        seq: 5,
        entryId: ext[1]!.entry_id,
      });
    });
  });

  it("batch beyond tip+1 -> writer_gap with the receiver's tip in details, nothing written", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 2);
      store.mergeEntries(chain);

      // Seq 4 skips 3 entirely.
      const gapped = extendChain(W_LOW, 1, 3, uuidv7());
      const error = catchError(() => store.mergeEntries(gapped));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("writer_gap");
      expect((error as StoreError).details).toMatchObject({
        writerId: W_LOW,
        expectedSeq: 3,
        tipEntryId: chain[1]!.entry_id,
      });
      expect(count(sql, "entries")).toBe(2);
      expect(tipsByWriter(sql).get(W_LOW)).toEqual({
        seq: 2,
        entryId: chain[1]!.entry_id,
      });
    });
  });

  it("different entry at an occupied coordinate -> writer_fork; original bytes intact (§8 inv 1)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 2);
      store.mergeEntries(chain);

      // A DIFFERENT entry at seq 2: fresh entry_id, correct prev link.
      const forked = {
        version: 1,
        log_id: LOG_ID,
        entry_id: uuidv7(),
        writer_id: W_LOW,
        writer_seq: 2,
        prev_entry_id: chain[0]!.entry_id,
        created_at: CREATED_AT,
        body: { divergent: true },
      };
      const error = catchError(() => store.mergeEntries([forked]));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("writer_fork");
      expect((error as StoreError).details).toMatchObject({ writerId: W_LOW, seq: 2 });

      // Original bytes at the coordinate are untouched — byte-compare.
      expect(count(sql, "entries")).toBe(2);
      const stored = storedBytes(sql, chain[1]!.entry_id as string);
      expect(Array.from(stored)).toEqual(Array.from(canonicalBytesOf(chain[1]!)));
    });
  });

  it("existing entry_id reused for different bytes -> entry_id_collision, nothing written", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 2);
      store.mergeEntries(chain);

      // Correct suffix position (seq 3, prev = tip) but the entry_id of
      // stored entry 1 — same id, different bytes.
      const colliding = {
        version: 1,
        log_id: LOG_ID,
        entry_id: chain[0]!.entry_id,
        writer_id: W_LOW,
        writer_seq: 3,
        prev_entry_id: chain[1]!.entry_id,
        created_at: CREATED_AT,
        body: { reused: true },
      };
      const error = catchError(() => store.mergeEntries([colliding]));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("entry_id_collision");
      expect((error as StoreError).details).toMatchObject({ entryId: chain[0]!.entry_id });
      expect(count(sql, "entries")).toBe(2);
      expect(tipsByWriter(sql).get(W_LOW)!.seq).toBe(2);
    });
  });

  it("§18 test 10 shape: mixed-writer batch with one poisoned writer rolls back BOTH writers", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const low = makeChain(W_LOW, 1);
      const high = makeChain(W_HIGH, 1);
      store.mergeEntries([...low, ...high]);
      const tipsBefore = tipsByWriter(sql);

      // W_LOW's part is a VALID extension (seq 2); W_HIGH's is gapped (seq 3
      // over tip 1). W_LOW sorts first, so its plan is built before the
      // poison is discovered — yet the whole batch must leave no trace.
      const validExt = extendChain(W_LOW, 1, 1, low[0]!.entry_id as string);
      const gapped = extendChain(W_HIGH, 1, 2, uuidv7());
      const error = catchError(() => store.mergeEntries([...validExt, ...gapped]));

      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("writer_gap");
      expect((error as StoreError).details).toMatchObject({ writerId: W_HIGH });

      // NOTHING was written for EITHER writer: counts and tips unchanged.
      expect(count(sql, "entries")).toBe(2);
      expect(
        Number(
          sql
            .exec("SELECT COUNT(*) AS n FROM entries WHERE writer_id = ?", W_LOW)
            .one().n,
        ),
      ).toBe(1);
      expect(tipsByWriter(sql)).toEqual(tipsBefore);
    });
  });

  it("fault on the LAST tip upsert of a multi-writer merge rolls back ALL inserts", async () => {
    await withStore(({ sql, store, makeStore, makeStoreWith }) => {
      store.createLog(LOG_ID);

      // Two fresh writers in one batch. The Proxy lets the first
      // writer_tips upsert through and faults the second (last) one, AFTER
      // every entries INSERT has succeeded — only a real transaction
      // rollback can erase those rows.
      let tipUpserts = 0;
      const faultedSql = new Proxy(sql, {
        get(target, prop) {
          if (prop === "exec") {
            return (query: string, ...bindings: unknown[]) => {
              if (query.includes("INSERT INTO writer_tips")) {
                tipUpserts++;
                if (tipUpserts === 2) {
                  throw new Error("injected fault: last writer_tips upsert");
                }
              }
              return target.exec(query, ...bindings);
            };
          }
          const value = Reflect.get(target, prop, target);
          return typeof value === "function" ? value.bind(target) : value;
        },
      }) as SqlStorage;

      const faulted = makeStoreWith(faultedSql);
      const batch = [...makeChain(W_LOW, 2), ...makeChain(W_HIGH, 2)];
      const error = catchError(() => faulted.mergeEntries(batch));

      // Positive control: the failure IS the injected fault — the merge got
      // past validation, all four INSERTs, and the first tip upsert.
      expect(error).toBeInstanceOf(Error);
      expect((error as Error).message).toContain("injected fault: last writer_tips upsert");
      expect(tipUpserts).toBe(2);

      expect(count(sql, "entries")).toBe(0);
      expect(count(sql, "writer_tips")).toBe(0);

      // A clean retry on an unwrapped store succeeds in full.
      const clean = makeStore().mergeEntries(batch);
      expect(clean.inserted).toBe(4);
      expect(count(sql, "entries")).toBe(4);
      expect(count(sql, "writer_tips")).toBe(2);
    });
  });

  it("valid-UUID but WRONG log_id -> log_mismatch (§8 inv 8), nothing written", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const foreign = makeChain(W_LOW, 1, OTHER_LOG_ID);
      const error = catchError(() => store.mergeEntries(foreign));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("log_mismatch");
      expect((error as StoreError).details).toMatchObject({
        entryLogId: OTHER_LOG_ID,
        expectedLogId: LOG_ID,
      });
      expect(count(sql, "entries")).toBe(0);
      expect(count(sql, "writer_tips")).toBe(0);
    });
  });

  it("malformed (non-UUID) log_id fails validation as invalid_entry, nothing written", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const [entry] = makeChain(W_LOW, 1);
      const error = catchError(() =>
        store.mergeEntries([{ ...entry!, log_id: "not-a-uuid" }]),
      );
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("invalid_entry");
      expect((error as StoreError).details).toMatchObject({ reason: "uuid-malformed" });
      expect(count(sql, "entries")).toBe(0);
    });
  });

  it("one invalid entry (bad entry_id UUID) poisons the whole batch: slugged error, nothing written", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const good = makeChain(W_LOW, 1);
      const bad = { ...makeChain(W_HIGH, 1)[0]!, entry_id: "ZZZ" };
      const error = catchError(() => store.mergeEntries([...good, bad]));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("invalid_entry");
      expect((error as StoreError).details).toMatchObject({ reason: "uuid-malformed" });
      // The valid W_LOW entry was NOT inserted either.
      expect(count(sql, "entries")).toBe(0);
      expect(count(sql, "writer_tips")).toBe(0);
    });
  });

  it("oversized entry -> entry_too_large with SP1's slug, nothing written", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const [entry] = makeChain(W_LOW, 1);
      const oversized = { ...entry!, body: { pad: "x".repeat(1_048_576) } };
      const error = catchError(() => store.mergeEntries([oversized]));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("entry_too_large");
      expect((error as StoreError).details).toMatchObject({
        reason: "canonical-bytes-over-1mib",
      });
      expect(count(sql, "entries")).toBe(0);
    });
  });

  it("a raw batch element that is not an object -> invalid_entry (entry-not-object)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const error = catchError(() => store.mergeEntries(["not an entry"]));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("invalid_entry");
      expect((error as StoreError).details).toMatchObject({ reason: "entry-not-object" });
      expect(count(sql, "entries")).toBe(0);
    });
  });

  it("intra-batch prev-link violation maps to invalid_entry (recorded invalid_batch decision)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 2);
      // Break the internal link: entry 2 names a random UUID, not entry 1.
      const broken = [chain[0]!, { ...chain[1]!, prev_entry_id: uuidv7() }];
      const error = catchError(() => store.mergeEntries(broken));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("invalid_entry");
      expect((error as StoreError).details).toMatchObject({
        reason: expect.stringContaining("prev_entry_id"),
      });
      expect(count(sql, "entries")).toBe(0);
    });
  });

  it("merge extends a chain built by append (append -> merge interop)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const a1 = store.append(W_LOW, { i: 1 }, CREATED_AT);
      const a2 = store.append(W_LOW, { i: 2 }, CREATED_AT);
      expect(a2.entry.writerSeq).toBe(2);

      const ext = extendChain(W_LOW, 2, 2, a2.entry.entryId);
      const result = store.mergeEntries(ext);
      expect(result.inserted).toBe(2);
      expect(result.frontier).toEqual([
        { writerId: W_LOW, seq: 4, entryId: ext[1]!.entry_id },
      ]);
      expect(count(sql, "entries")).toBe(4);
    });
  });

  it("append continues after merge from the merged tip (merge -> append interop)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 3);
      store.mergeEntries(chain);

      const next = store.append(W_LOW, { after: "merge" }, CREATED_AT);
      expect(next.entry.writerSeq).toBe(4);
      expect(next.entry.prevEntryId).toBe(chain[2]!.entry_id);
      expect(tipsByWriter(sql).get(W_LOW)).toEqual({
        seq: 4,
        entryId: next.entry.entryId,
      });
    });
  });

  it("a permuted (unsorted writer_seq) batch inserts identically to sorted (§9.3 rule 1)", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 3);
      const permuted = [chain[2]!, chain[0]!, chain[1]!];
      const result = store.mergeEntries(permuted);

      expect(result.inserted).toBe(3);
      expect(result.present).toBe(0);
      expect(result.frontier).toEqual([
        { writerId: W_LOW, seq: 3, entryId: chain[2]!.entry_id },
      ]);
      // Stored state is the fully-chained prefix with exact canonical bytes.
      const rows = sql
        .exec(
          "SELECT entry_id, writer_seq, prev_entry_id FROM entries ORDER BY writer_seq",
        )
        .toArray();
      expect(rows.map((r) => r.entry_id)).toEqual(chain.map((e) => e.entry_id));
      expect(rows[0]!.prev_entry_id).toBeNull();
      expect(rows[1]!.prev_entry_id).toBe(chain[0]!.entry_id);
      expect(rows[2]!.prev_entry_id).toBe(chain[1]!.entry_id);
      for (const entry of chain) {
        expect(Array.from(storedBytes(sql, entry.entry_id as string))).toEqual(
          Array.from(canonicalBytesOf(entry)),
        );
      }
    });
  });

  it("empty batch returns inserted 0 / present 0 and the current frontier", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 2);
      store.mergeEntries(chain);

      const result = store.mergeEntries([]);
      expect(result.inserted).toBe(0);
      expect(result.present).toBe(0);
      expect(result.frontier).toEqual([
        { writerId: W_LOW, seq: 2, entryId: chain[1]!.entry_id },
      ]);
      expect(count(sql, "entries")).toBe(2);
    });
  });

  it("adversarial getter flipping entry_id between reads cannot desync columns from canonical bytes", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const idA = uuidv7();
      const idB = uuidv7();

      // Reviewer's b1 shape: entry_id reads as A the FIRST time (the read
      // canonicalize consumes into the canonical bytes) and B on every
      // later read. The canonical bytes — what validateEntry blessed and
      // what gets stored — must be the single source of truth for the
      // columns too, so the store must record entry_id = A everywhere.
      let reads = 0;
      const shifty = {
        version: 1,
        log_id: LOG_ID,
        get entry_id() {
          reads++;
          return reads === 1 ? idA : idB;
        },
        writer_id: W_LOW,
        writer_seq: 1,
        prev_entry_id: null,
        created_at: CREATED_AT,
        body: { shifty: true },
      };
      const result = store.mergeEntries([shifty]);
      expect(reads).toBeGreaterThanOrEqual(1); // positive control: getter live
      expect(result.inserted).toBe(1);
      expect(result.frontier).toEqual([{ writerId: W_LOW, seq: 1, entryId: idA }]);

      // The row's column matches the id INSIDE its own stored bytes.
      const row = sql
        .exec("SELECT entry_id, canonical_json FROM entries WHERE writer_id = ?", W_LOW)
        .one();
      expect(row.entry_id).toBe(idA);
      const inBytes = JSON.parse(
        new TextDecoder().decode(new Uint8Array(row.canonical_json as ArrayBuffer)),
      ) as Record<string, unknown>;
      expect(inBytes.entry_id).toBe(idA);
      expect(tipsByWriter(sql).get(W_LOW)).toEqual({ seq: 1, entryId: idA });

      // Re-merging the same canonical entry (as an honest plain object) is
      // idempotent: the store treats it as already present.
      const honest = {
        version: 1,
        log_id: LOG_ID,
        entry_id: idA,
        writer_id: W_LOW,
        writer_seq: 1,
        prev_entry_id: null,
        created_at: CREATED_AT,
        body: { shifty: true },
      };
      const again = store.mergeEntries([honest]);
      expect(again.inserted).toBe(0);
      expect(again.present).toBe(1);

      // The guarded invariant, store-wide: NO stored row's identity columns
      // may disagree with the fields inside its own canonical bytes.
      for (const r of sql
        .exec("SELECT entry_id, writer_id, writer_seq, canonical_json FROM entries")
        .toArray()) {
        const parsed = JSON.parse(
          new TextDecoder().decode(new Uint8Array(r.canonical_json as ArrayBuffer)),
        ) as Record<string, unknown>;
        expect(r.entry_id).toBe(parsed.entry_id);
        expect(r.writer_id).toBe(parsed.writer_id);
        expect(Number(r.writer_seq)).toBe(parsed.writer_seq);
      }
    });
  });

  it("exact duplicate WITHIN one batch is deduplicated and counted present", async () => {
    await withStore(({ sql, store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 2);
      const result = store.mergeEntries([chain[0]!, chain[1]!, chain[0]!]);
      expect(result.inserted).toBe(2);
      expect(result.present).toBe(1);
      expect(count(sql, "entries")).toBe(2);
      expect(tipsByWriter(sql).get(W_LOW)).toEqual({
        seq: 2,
        entryId: chain[1]!.entry_id,
      });
    });
  });
});
