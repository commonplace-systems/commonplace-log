import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { validateEntry } from "../../src/entry";
import { LogStore, StoreError } from "../../src/do/store";
import { uuidv7 } from "../../src/do/uuid";

/**
 * SP2 Task 6: the store's read operations — frontier (§9.4), readWriter
 * (§9.5), tailLocal (§9.6) — over real DO SQLite.
 *
 * Every assertion is verified by effect against actual SQLite state, and
 * stored bytes are compared against SP1's validateEntry canonical bytes —
 * the store is never its own byte oracle.
 *
 * Anti-vacuity: this file registers 22 tests (>= the 14-test floor).
 */

const LOG_ID = "0198cc6e-47ac-7d72-93db-b6fbd92bfca2";
// Writer ids with a KNOWN lexicographic order (low < mid < high) so
// frontier-sorting assertions are non-vacuous.
const W_LOW = "0b7bc7de-92ee-4d63-9d1c-8b7f0f3a2c11";
const W_MID = "7c1d2e3f-4a5b-4c6d-8e7f-901234567890";
const W_HIGH = "fab4e8a5-ce9e-48d0-8f78-1d312b978207";
const CREATED_AT = "2026-08-22T12:00:00Z";

type RawEntry = Record<string, unknown>;

interface StoreCtx {
  sql: SqlStorage;
  store: LogStore;
}

async function withStore<T>(fn: (ctx: StoreCtx) => T): Promise<T> {
  const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName("reads-test"));
  return await runInDurableObject(stub, (_instance, state) => {
    const store = new LogStore(state.storage.sql, state.storage);
    return fn({ sql: state.storage.sql, store });
  });
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
function makeChain(writerId: string, n: number): RawEntry[] {
  return extendChain(writerId, n, 0, null);
}

/** n further entries for a writer, continuing after (lastSeq, lastEntryId). */
function extendChain(
  writerId: string,
  n: number,
  lastSeq: number,
  lastEntryId: string | null,
): RawEntry[] {
  const entries: RawEntry[] = [];
  let prev = lastEntryId;
  for (let i = 1; i <= n; i++) {
    const seq = lastSeq + i;
    const entryId = uuidv7();
    entries.push({
      version: 1,
      log_id: LOG_ID,
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

function bytesEqual(a: Uint8Array, b: Uint8Array): boolean {
  if (a.byteLength !== b.byteLength) return false;
  for (let i = 0; i < a.byteLength; i++) {
    if (a[i] !== b[i]) return false;
  }
  return true;
}

/** Decode stored canonical bytes back into the entry's identity fields. */
function decodeEntry(bytes: Uint8Array): { entry_id: string; writer_id: string; writer_seq: number } {
  return JSON.parse(new TextDecoder().decode(bytes)) as {
    entry_id: string;
    writer_id: string;
    writer_seq: number;
  };
}

describe("frontier (§9.4)", () => {
  it("before createLog fails with log_not_found", async () => {
    await withStore(({ store }) => {
      const error = catchError(() => store.frontier());
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("log_not_found");
    });
  });

  it("empty log -> [] (writers with no entries are omitted)", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      expect(store.frontier()).toEqual([]);
    });
  });

  it("three writers appended out of lexicographic order -> sorted by writerId", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      // Deliberately insert high, low, mid — NOT sorted order.
      store.append(W_HIGH, { i: 1 }, CREATED_AT);
      store.append(W_LOW, { i: 1 }, CREATED_AT);
      store.append(W_MID, { i: 1 }, CREATED_AT);

      const frontier = store.frontier();
      expect(frontier.map((f) => f.writerId)).toEqual([W_LOW, W_MID, W_HIGH]);
      // Non-vacuity: insertion order genuinely differed from sorted order.
      expect([W_HIGH, W_LOW, W_MID]).not.toEqual([W_LOW, W_MID, W_HIGH]);
    });
  });

  it("each writer appears ONCE with its TIP entry, not its first entry", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      const first = store.append(W_LOW, { i: 1 }, CREATED_AT);
      store.append(W_LOW, { i: 2 }, CREATED_AT);
      const tip = store.append(W_LOW, { i: 3 }, CREATED_AT);
      expect(tip.entry.entryId).not.toBe(first.entry.entryId);

      const frontier = store.frontier();
      expect(frontier).toHaveLength(1);
      expect(frontier[0]).toEqual({
        writerId: W_LOW,
        seq: 3,
        entryId: tip.entry.entryId,
      });
    });
  });

  it("reflects mixed merge AND append state across writers", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      // W_MID arrives via merge (a remote writer), W_HIGH via local appends.
      const midChain = makeChain(W_MID, 2);
      store.mergeEntries(midChain);
      store.append(W_HIGH, { i: 1 }, CREATED_AT);
      const highTip = store.append(W_HIGH, { i: 2 }, CREATED_AT);

      const frontier = store.frontier();
      expect(frontier).toEqual([
        {
          writerId: W_MID,
          seq: 2,
          entryId: midChain[1]!.entry_id,
        },
        {
          writerId: W_HIGH,
          seq: 2,
          entryId: highTip.entry.entryId,
        },
      ]);
    });
  });

  it("equals the frontier mergeEntries returns for the same state (single code path)", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      store.append(W_HIGH, { i: 1 }, CREATED_AT);
      const result = store.mergeEntries([
        ...makeChain(W_LOW, 2),
        ...makeChain(W_MID, 1),
      ]);
      // The two public views of the frontier MUST agree exactly.
      expect(store.frontier()).toEqual(result.frontier);
      // And non-vacuously: the state has three writers.
      expect(result.frontier).toHaveLength(3);
    });
  });
});

describe("readWriter (§9.5)", () => {
  it("afterSeq=0 with through=null returns the full chain from seq 1, ascending", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 4);
      store.mergeEntries(chain);

      const result = store.readWriter(W_LOW, 0, null, 100);
      expect(result.entries.map((e) => e.writerSeq)).toEqual([1, 2, 3, 4]);
      expect(result.nextAfterSeq).toBeNull();
      // Byte-for-byte the canonical bytes SP1 derives for the fixtures.
      for (let i = 0; i < 4; i++) {
        expect(
          bytesEqual(result.entries[i]!.canonicalBytes, canonicalBytesOf(chain[i]!)),
        ).toBe(true);
      }
    });
  });

  it("range is EXCLUSIVE of afterSeq, INCLUSIVE of throughSeq: after=2 through=4 -> exactly [3,4]", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 6);
      store.mergeEntries(chain);

      const result = store.readWriter(W_LOW, 2, 4, 100);
      expect(result.entries.map((e) => e.writerSeq)).toEqual([3, 4]);
      expect(result.nextAfterSeq).toBeNull();
      expect(bytesEqual(result.entries[0]!.canonicalBytes, canonicalBytesOf(chain[2]!))).toBe(true);
      expect(bytesEqual(result.entries[1]!.canonicalBytes, canonicalBytesOf(chain[3]!))).toBe(true);
    });
  });

  it("throughSeq beyond the tip clamps to the tip (no phantom continuation)", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      store.mergeEntries(makeChain(W_LOW, 3));

      const result = store.readWriter(W_LOW, 1, 999, 100);
      expect(result.entries.map((e) => e.writerSeq)).toEqual([2, 3]);
      // The range is exhausted at the tip: no cursor.
      expect(result.nextAfterSeq).toBeNull();
    });
  });

  it("limit truncates mid-range and nextAfterSeq is the LAST RETURNED seq", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      store.mergeEntries(makeChain(W_LOW, 8));

      const result = store.readWriter(W_LOW, 1, 7, 3);
      expect(result.entries.map((e) => e.writerSeq)).toEqual([2, 3, 4]);
      expect(result.nextAfterSeq).toBe(4);
    });
  });

  it("limit reaching exactly the end of the range yields NO cursor", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      const chain = makeChain(W_LOW, 5);
      store.mergeEntries(chain);

      // Range 3..5 has exactly 3 entries; limit 3 exhausts it.
      const result = store.readWriter(W_LOW, 2, 5, 3);
      expect(result.entries.map((e) => e.writerSeq)).toEqual([3, 4, 5]);
      expect(result.nextAfterSeq).toBeNull();

      // Same range with tip headroom BEYOND throughSeq: still no cursor —
      // the requested range (not the tip) bounds "more remain".
      store.mergeEntries(extendChain(W_LOW, 2, 5, String(chain[4]!.entry_id)));
      const withHeadroom = store.readWriter(W_LOW, 2, 5, 3);
      expect(withHeadroom.entries.map((e) => e.writerSeq)).toEqual([3, 4, 5]);
      expect(withHeadroom.nextAfterSeq).toBeNull();
    });
  });

  it("paging a 10-entry chain in pages of 3 reassembles the full read byte-for-byte, no gap/overlap", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      store.mergeEntries(makeChain(W_LOW, 10));

      const full = store.readWriter(W_LOW, 0, null, 100);
      expect(full.entries).toHaveLength(10);

      const pages: Array<{ canonicalBytes: Uint8Array; writerSeq: number }> = [];
      let after = 0;
      let rounds = 0;
      for (;;) {
        const page = store.readWriter(W_LOW, after, null, 3);
        pages.push(...page.entries);
        rounds++;
        if (page.nextAfterSeq === null) break;
        // Cursor is the last returned seq.
        expect(page.nextAfterSeq).toBe(page.entries[page.entries.length - 1]!.writerSeq);
        after = page.nextAfterSeq;
        expect(rounds).toBeLessThan(20); // runaway guard
      }
      expect(rounds).toBe(4); // 3+3+3+1

      // Reassembly equals the single full read byte-for-byte.
      expect(pages).toHaveLength(10);
      for (let i = 0; i < 10; i++) {
        expect(pages[i]!.writerSeq).toBe(full.entries[i]!.writerSeq);
        expect(bytesEqual(pages[i]!.canonicalBytes, full.entries[i]!.canonicalBytes)).toBe(true);
      }
    });
  });

  it("returned seqs are consecutive integers (complete contiguous range, anti-gap)", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      store.mergeEntries(makeChain(W_MID, 7));

      const result = store.readWriter(W_MID, 1, null, 100);
      const seqs = result.entries.map((e) => e.writerSeq);
      expect(seqs[0]).toBe(2);
      for (let i = 1; i < seqs.length; i++) {
        expect(seqs[i]).toBe(seqs[i - 1]! + 1);
      }
      expect(seqs[seqs.length - 1]).toBe(7);
      // And the seq inside each entry's own bytes agrees with the column.
      for (const e of result.entries) {
        expect(decodeEntry(e.canonicalBytes).writer_seq).toBe(e.writerSeq);
      }
    });
  });

  it("unknown writerId -> empty entries and null cursor (NOT an error; §10 sync may probe)", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      store.mergeEntries(makeChain(W_LOW, 2)); // corpus non-empty
      const result = store.readWriter(W_HIGH, 0, null, 100);
      expect(result.entries).toEqual([]);
      expect(result.nextAfterSeq).toBeNull();
    });
  });

  it("before createLog fails with log_not_found", async () => {
    await withStore(({ store }) => {
      const error = catchError(() => store.readWriter(W_LOW, 0, null, 100));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("log_not_found");
    });
  });

  it("caller-contract violations throw RangeError: negative afterSeq, zero/negative limit, bad throughSeq", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      store.mergeEntries(makeChain(W_LOW, 2));
      expect(() => store.readWriter(W_LOW, -1, null, 10)).toThrow(RangeError);
      expect(() => store.readWriter(W_LOW, 0, null, 0)).toThrow(RangeError);
      expect(() => store.readWriter(W_LOW, 0, null, -5)).toThrow(RangeError);
      expect(() => store.readWriter(W_LOW, 0, -1, 10)).toThrow(RangeError);
      expect(() => store.readWriter(W_LOW, 1.5, null, 10)).toThrow(RangeError);
      // And a valid call still works afterwards (guards are pure checks).
      expect(store.readWriter(W_LOW, 0, null, 10).entries).toHaveLength(2);
    });
  });
});

describe("tailLocal (§9.6)", () => {
  it("returns entries in ARRIVAL order even when it diverges from writer order", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      // Interleave two writers via separate merges so arrival order is
      // B1, A1, B2, A2 while (writer_id, writer_seq) order is A1, A2, B1, B2.
      const a = makeChain(W_LOW, 2); // lexicographically FIRST writer
      const b = makeChain(W_HIGH, 2); // lexicographically LAST writer
      store.mergeEntries([b[0]!]);
      store.mergeEntries([a[0]!]);
      store.mergeEntries([b[1]!]);
      store.mergeEntries([a[1]!]);

      const tail = store.tailLocal(0, 100);
      expect(tail.entries).toHaveLength(4);
      expect(tail.nextAfterArrival).toBeNull();

      const arrivalIds = tail.entries.map((e) => decodeEntry(e.canonicalBytes).entry_id);
      const writerOrderIds = [a[0]!, a[1]!, b[0]!, b[1]!].map((e) => String(e.entry_id));
      // Non-vacuity: the two orders GENUINELY differ for this state.
      expect(arrivalIds).not.toEqual(writerOrderIds);
      // And the tail is exactly the arrival (insertion) order.
      expect(arrivalIds).toEqual([b[0]!, a[0]!, b[1]!, a[1]!].map((e) => String(e.entry_id)));
      // arrivalSeq is strictly increasing.
      const arrivals = tail.entries.map((e) => e.arrivalSeq);
      for (let i = 1; i < arrivals.length; i++) {
        expect(arrivals[i]!).toBeGreaterThan(arrivals[i - 1]!);
      }
    });
  });

  it("pages via nextAfterArrival with no gap/overlap and terminates with null", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      for (let i = 0; i < 7; i++) {
        store.append(W_MID, { i }, CREATED_AT);
      }
      const full = store.tailLocal(0, 100);
      expect(full.entries).toHaveLength(7);

      const pages: Array<{ canonicalBytes: Uint8Array; arrivalSeq: number }> = [];
      let after = 0;
      let rounds = 0;
      for (;;) {
        const page = store.tailLocal(after, 3);
        pages.push(...page.entries);
        rounds++;
        if (page.nextAfterArrival === null) break;
        expect(page.nextAfterArrival).toBe(page.entries[page.entries.length - 1]!.arrivalSeq);
        after = page.nextAfterArrival;
        expect(rounds).toBeLessThan(20);
      }
      expect(rounds).toBe(3); // 3+3+1
      expect(pages.map((e) => e.arrivalSeq)).toEqual(full.entries.map((e) => e.arrivalSeq));
      for (let i = 0; i < 7; i++) {
        expect(bytesEqual(pages[i]!.canonicalBytes, full.entries[i]!.canonicalBytes)).toBe(true);
      }
    });
  });

  it("afterArrival at or beyond the max arrival -> empty entries and null cursor", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      store.append(W_MID, { i: 1 }, CREATED_AT);
      const { arrivalSeq } = store.append(W_MID, { i: 2 }, CREATED_AT);

      const atMax = store.tailLocal(arrivalSeq, 100);
      expect(atMax.entries).toEqual([]);
      expect(atMax.nextAfterArrival).toBeNull();

      const beyond = store.tailLocal(arrivalSeq + 1000, 100);
      expect(beyond.entries).toEqual([]);
      expect(beyond.nextAfterArrival).toBeNull();
    });
  });

  it("empty log -> empty entries and null cursor", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      const result = store.tailLocal(0, 100);
      expect(result.entries).toEqual([]);
      expect(result.nextAfterArrival).toBeNull();
    });
  });

  it("before createLog fails with log_not_found", async () => {
    await withStore(({ store }) => {
      const error = catchError(() => store.tailLocal(0, 100));
      expect(error).toBeInstanceOf(StoreError);
      expect((error as StoreError).code).toBe("log_not_found");
    });
  });

  it("caller-contract violations throw RangeError: negative afterArrival, zero/negative limit", async () => {
    await withStore(({ store }) => {
      store.createLog(LOG_ID);
      store.append(W_MID, { i: 1 }, CREATED_AT);
      expect(() => store.tailLocal(-1, 10)).toThrow(RangeError);
      expect(() => store.tailLocal(0, 0)).toThrow(RangeError);
      expect(() => store.tailLocal(0, -3)).toThrow(RangeError);
      expect(() => store.tailLocal(0.5, 10)).toThrow(RangeError);
      // And a valid call still works afterwards.
      expect(store.tailLocal(0, 10).entries).toHaveLength(1);
    });
  });
});
