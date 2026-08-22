import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { LogStore } from "../../src/do/store";
import { uuidv7 } from "../../src/do/uuid";
import {
  CREATED_AT,
  LOG_ID,
  W_HIGH,
  W_LOW,
  W_MID,
  appendOn,
  arrivalOrderOf,
  auditReplica,
  auditStore,
  createReplica,
  entryByteSetOf,
  expectAuditClean,
  expectReplicaAuditClean,
  extendChain,
  frontierOf,
  httpOn,
  makeChain,
  mergeErrorInto,
  mergeInto,
  onReplica,
  readWriterPage,
  syncOneDirection,
  toHex,
} from "./helpers";

/**
 * SP2 Task 8: the §18 conformance suite, items 1–12, against REAL Durable
 * Object SQLite storage (each named replica is its own DO with its own
 * database), plus the §15.2 restart-durability test and the audit-can-fail
 * demonstration.
 *
 * Driving surfaces (plan Task 8): items 1 and 7 drive the store API; items
 * 2, 6, 8, 9, 10 drive the §11 HTTP surface via handleRequest over real
 * storage (the http.test.ts harness pattern — ctx.id.name is always
 * undefined under the pool, so objectName is injected); items 3, 4, 5, 11,
 * 12 run two or more LogStore replicas over SEPARATE real DO storages
 * (different idFromName ids) and synchronize them per §10.
 *
 * Every scenario ends with the helpers.ts audit re-proving the §8 invariants
 * from stored state; one extra test corrupts a scratch replica via a
 * trigger-legal direct INSERT to demonstrate the audit can go red.
 */

/** Registry of §18-numbered tests, counted by the anti-vacuity gate below. */
const SPEC_TESTS: string[] = [];
function specTest(name: `§18.${number} ${string}`, fn: () => Promise<void>): void {
  SPEC_TESTS.push(name);
  it(name, fn);
}

interface WireError {
  code: string;
  message: string;
  details?: Record<string, unknown>;
}

function expectHttpError(
  res: { status: number; body: { error?: WireError } },
  status: number,
  code: string,
): WireError {
  expect(res.status).toBe(status);
  const error = res.body.error as WireError;
  expect(error.code).toBe(code);
  return error;
}

describe("§18 conformance (items 1–12)", () => {
  specTest("§18.1 repeating one append produces one stored entry", async () => {
    // Store surface. §9.2 append allocates the coordinate; §15.1's retry
    // contract is that the client re-submits the IDENTICAL produced entry —
    // the store reports it already present and stores nothing new. (An
    // HTTP-level retry of the produced entry is item 2's shape.)
    const R = "r1";
    await createReplica(R);
    const produced = await appendOn(R, W_LOW, { note: "only once" });

    // Repeat the identical append twice more.
    for (let i = 0; i < 2; i++) {
      const again = await mergeInto(R, [produced]);
      expect(again.inserted).toBe(0);
      expect(again.present).toBe(1);
    }

    const stored = await onReplica(R, ({ sql }) =>
      sql.exec("SELECT COUNT(*) AS n FROM entries").one(),
    );
    expect(Number(stored.n)).toBe(1);
    expect(await frontierOf(R)).toEqual([
      { writerId: W_LOW, seq: 1, entryId: produced["entry_id"] },
    ]);
    await expectReplicaAuditClean(R);
  });

  specTest("§18.2 retrying after a simulated lost acknowledgement is idempotent", async () => {
    // HTTP surface. The merge commits and the 200 response (the ack) is
    // dropped on the floor by the client; the retry MUST reuse the same
    // entry objects (§11.6) and the store returns them as present (§15.1).
    await httpOn(LOG_ID, "PUT", `/v1/logs/${LOG_ID}`, { version: 1 });
    const entries = makeChain(W_LOW, 3);

    const first = await httpOn(LOG_ID, "POST", `/v1/logs/${LOG_ID}/entries`, { entries });
    expect(first.status).toBe(200);
    expect(first.body.inserted).toBe(3);
    // ...the client never sees `first` — it retries the identical POST:
    const retry = await httpOn(LOG_ID, "POST", `/v1/logs/${LOG_ID}/entries`, { entries });
    expect(retry.status).toBe(200);
    expect(retry.body.inserted).toBe(0);
    expect(retry.body.present).toBe(3);
    expect(retry.body.frontier).toEqual(first.body.frontier);

    const n = await onReplica(LOG_ID, ({ sql }) =>
      Number(sql.exec("SELECT COUNT(*) AS n FROM entries").one().n),
    );
    expect(n).toBe(3); // present, not duplicated
    await expectReplicaAuditClean(LOG_ID);
  });

  specTest(
    "§18.3 two replicas appending under different writer IDs converge in either sync order",
    async () => {
      // Two replica PAIRS over four real DO storages, seeded with the SAME
      // entries; pair 1 syncs A-side first, pair 2 syncs B-side first.
      const chainA = makeChain(W_LOW, 3);
      const chainB = makeChain(W_HIGH, 2);
      for (const r of ["r3-a1", "r3-b1", "r3-a2", "r3-b2"]) await createReplica(r);
      await mergeInto("r3-a1", chainA);
      await mergeInto("r3-a2", chainA);
      await mergeInto("r3-b1", chainB);
      await mergeInto("r3-b2", chainB);

      // Pair 1: transfer A→B first, then B→A.
      await syncOneDirection("r3-a1", "r3-b1", 100);
      await syncOneDirection("r3-b1", "r3-a1", 100);
      // Pair 2: the OPPOSITE order.
      await syncOneDirection("r3-b2", "r3-a2", 100);
      await syncOneDirection("r3-a2", "r3-b2", 100);

      const replicas = ["r3-a1", "r3-b1", "r3-a2", "r3-b2"];
      const expected = [
        { writerId: W_LOW, seq: 3, entryId: chainA[2]!["entry_id"] },
        { writerId: W_HIGH, seq: 2, entryId: chainB[1]!["entry_id"] },
      ];
      const referenceSet = await entryByteSetOf("r3-a1");
      expect(referenceSet).toHaveLength(5); // anti-vacuity: the set is non-empty
      for (const r of replicas) {
        expect(await frontierOf(r), `frontier of ${r}`).toEqual(expected);
        expect(await entryByteSetOf(r), `byte set of ${r}`).toEqual(referenceSet);
      }
      await expectReplicaAuditClean("r3-a1", "r3-b1", "r3-a2", "r3-b2");
    },
  );

  specTest("§18.4 three-way merge is associative for compatible replicas", async () => {
    // Compatible states sharing writers with prefix relations (§5):
    //   A = { w_low: [1..3] }
    //   B = { w_low: [1..5], w_mid: [1..2] }
    //   C = { w_mid: [1..4], w_high: [1..2] }
    const chainLow = makeChain(W_LOW, 5);
    const chainMid = makeChain(W_MID, 4);
    const chainHigh = makeChain(W_HIGH, 2);
    const stateA = chainLow.slice(0, 3);
    const stateB = [...chainLow, ...chainMid.slice(0, 2)];
    const stateC = [...chainMid, ...chainHigh];

    // Left: (A ∪ B) ∪ C materialized on replica L.
    await createReplica("r4-left");
    await mergeInto("r4-left", stateA);
    await mergeInto("r4-left", stateB); // L = A ∪ B
    await mergeInto("r4-left", stateC); // L = (A ∪ B) ∪ C

    // Right: B ∪ C materialized on replica M first, then A ∪ (B ∪ C) on R
    // by merging M's ACTUAL stored contents (read back page-wise), not the
    // fixture arrays — so the intermediate state is the real merged one.
    await createReplica("r4-mid");
    await mergeInto("r4-mid", stateB);
    await mergeInto("r4-mid", stateC); // M = B ∪ C
    await createReplica("r4-right");
    await mergeInto("r4-right", stateA); // R = A
    for (const tip of await frontierOf("r4-mid")) {
      const page = await readWriterPage("r4-mid", tip.writerId, 0, null, 1000);
      await mergeInto("r4-right", page.entries); // R = A ∪ (B ∪ C)
    }

    const left = await entryByteSetOf("r4-left");
    const right = await entryByteSetOf("r4-right");
    expect(left).toHaveLength(11); // 5 + 4 + 2 — anti-vacuity
    expect(right).toEqual(left);
    expect(await frontierOf("r4-right")).toEqual(await frontierOf("r4-left"));
    await expectReplicaAuditClean("r4-left", "r4-mid", "r4-right");
  });

  specTest(
    "§18.5 a shorter writer prefix extends to the longer prefix page by page",
    async () => {
      const chain = makeChain(W_LOW, 7);
      await createReplica("r5-long");
      await mergeInto("r5-long", chain);
      await createReplica("r5-short");
      await mergeInto("r5-short", chain.slice(0, 3)); // the shorter prefix

      // Page size 2 over the 4 missing entries (seqs 4–7): exactly 2 pages.
      const pages = await syncOneDirection("r5-long", "r5-short", 2);
      expect(pages).toBe(2);

      expect(await frontierOf("r5-short")).toEqual([
        { writerId: W_LOW, seq: 7, entryId: chain[6]!["entry_id"] },
      ]);
      expect(await entryByteSetOf("r5-short")).toEqual(await entryByteSetOf("r5-long"));
      await expectReplicaAuditClean("r5-long", "r5-short");
    },
  );

  specTest("§18.6 a missing sequence is rejected without partial insertion", async () => {
    // HTTP surface. Store has seqs 1–2; the batch offers 4–5 (3 missing).
    await httpOn(LOG_ID, "PUT", `/v1/logs/${LOG_ID}`, { version: 1 });
    const chain = makeChain(W_LOW, 2);
    await httpOn(LOG_ID, "POST", `/v1/logs/${LOG_ID}/entries`, { entries: chain });

    const gapped = extendChain(W_LOW, 2, 3, uuidv7()); // seqs 4–5
    const res = await httpOn(LOG_ID, "POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: gapped,
    });
    const error = expectHttpError(res, 409, "writer_gap");
    expect(error.details).toEqual({
      writer_id: W_LOW,
      expected_seq: 3,
      tip_entry_id: chain[1]!["entry_id"],
    });

    // No partial insertion: counts and tip exactly as before the batch.
    const after = await onReplica(LOG_ID, ({ sql }) => ({
      entries: Number(sql.exec("SELECT COUNT(*) AS n FROM entries").one().n),
      tips: sql.exec("SELECT writer_id, last_seq, last_entry_id FROM writer_tips").toArray(),
    }));
    expect(after.entries).toBe(2);
    expect(after.tips).toEqual([
      { writer_id: W_LOW, last_seq: 2, last_entry_id: chain[1]!["entry_id"] },
    ]);
    await expectReplicaAuditClean(LOG_ID);
  });

  specTest("§18.7 a predecessor mismatch is reported as a writer fork", async () => {
    // Store surface. The entry sits at EXACTLY the expected next sequence
    // (tip+1 — so this is not a gap) but its prev_entry_id names a different
    // chain than the local tip (§9.3 rule 4 / §10 step 4).
    const R = "r7";
    await createReplica(R);
    const chain = makeChain(W_LOW, 2);
    await mergeInto(R, chain);

    const mismatched = {
      version: 1,
      log_id: LOG_ID,
      entry_id: uuidv7(),
      writer_id: W_LOW,
      writer_seq: 3, // correct next seq
      prev_entry_id: uuidv7(), // does NOT name the tip (chain[1])
      created_at: CREATED_AT,
      body: { divergent: true },
    };
    const error = await mergeErrorInto(R, [mismatched]);
    expect(error).toEqual({
      code: "writer_fork",
      details: { writerId: W_LOW, seq: 3 },
    });

    const n = await onReplica(R, ({ sql }) =>
      Number(sql.exec("SELECT COUNT(*) AS n FROM entries").one().n),
    );
    expect(n).toBe(2); // nothing written
    await expectReplicaAuditClean(R);
  });

  specTest("§18.8 different entries at one writer coordinate are rejected", async () => {
    // HTTP surface. A rival entry occupies (W_LOW, 2) with a fresh entry_id
    // and the CORRECT prev link — only its content differs. 409 writer_fork,
    // and the originally stored bytes at the coordinate are untouched.
    await httpOn(LOG_ID, "PUT", `/v1/logs/${LOG_ID}`, { version: 1 });
    const chain = makeChain(W_LOW, 2);
    await httpOn(LOG_ID, "POST", `/v1/logs/${LOG_ID}/entries`, { entries: chain });
    const originalBytes = await onReplica(LOG_ID, ({ sql }) =>
      toHex(
        new Uint8Array(
          sql
            .exec("SELECT canonical_json FROM entries WHERE entry_id = ?", chain[1]!["entry_id"])
            .one().canonical_json as ArrayBuffer,
        ),
      ),
    );

    const rival = {
      version: 1,
      log_id: LOG_ID,
      entry_id: uuidv7(),
      writer_id: W_LOW,
      writer_seq: 2,
      prev_entry_id: chain[0]!["entry_id"],
      created_at: CREATED_AT,
      body: { rival: true },
    };
    const res = await httpOn(LOG_ID, "POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: [rival],
    });
    const error = expectHttpError(res, 409, "writer_fork");
    expect(error.details).toEqual({ writer_id: W_LOW, seq: 2 });

    const after = await onReplica(LOG_ID, ({ sql }) => ({
      n: Number(sql.exec("SELECT COUNT(*) AS n FROM entries").one().n),
      bytes: toHex(
        new Uint8Array(
          sql
            .exec("SELECT canonical_json FROM entries WHERE writer_id = ? AND writer_seq = 2", W_LOW)
            .one().canonical_json as ArrayBuffer,
        ),
      ),
    }));
    expect(after.n).toBe(2);
    expect(after.bytes).toBe(originalBytes); // original intact, byte-for-byte
    await expectReplicaAuditClean(LOG_ID);
  });

  specTest("§18.9 reusing an entry UUID with different bytes is rejected", async () => {
    // HTTP surface. A structurally valid successor entry (seq 3, correct
    // prev) reuses stored entry 1's UUID for different bytes (§6.3).
    await httpOn(LOG_ID, "PUT", `/v1/logs/${LOG_ID}`, { version: 1 });
    const chain = makeChain(W_LOW, 2);
    await httpOn(LOG_ID, "POST", `/v1/logs/${LOG_ID}/entries`, { entries: chain });

    const colliding = {
      version: 1,
      log_id: LOG_ID,
      entry_id: chain[0]!["entry_id"], // reused UUID
      writer_id: W_LOW,
      writer_seq: 3,
      prev_entry_id: chain[1]!["entry_id"],
      created_at: CREATED_AT,
      body: { different: "bytes" },
    };
    const res = await httpOn(LOG_ID, "POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: [colliding],
    });
    const error = expectHttpError(res, 409, "entry_id_collision");
    expect(error.details).toEqual({ entry_id: chain[0]!["entry_id"] });

    const n = await onReplica(LOG_ID, ({ sql }) =>
      Number(sql.exec("SELECT COUNT(*) AS n FROM entries").one().n),
    );
    expect(n).toBe(2);
    await expectReplicaAuditClean(LOG_ID);
  });

  specTest("§18.10 a mixed-writer batch either commits completely or not at all", async () => {
    // HTTP surface. W_LOW's half is a perfectly valid extension; W_HIGH's is
    // gapped. The whole batch must vanish: BOTH writers' counts and tips
    // stay exactly as they were.
    await httpOn(LOG_ID, "PUT", `/v1/logs/${LOG_ID}`, { version: 1 });
    const low = makeChain(W_LOW, 1);
    const high = makeChain(W_HIGH, 1);
    await httpOn(LOG_ID, "POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: [...low, ...high],
    });
    const before = await onReplica(LOG_ID, ({ sql }) => ({
      counts: sql
        .exec("SELECT writer_id, COUNT(*) AS n FROM entries GROUP BY writer_id ORDER BY writer_id")
        .toArray(),
      tips: sql
        .exec("SELECT writer_id, last_seq, last_entry_id FROM writer_tips ORDER BY writer_id")
        .toArray(),
    }));

    const validExt = extendChain(W_LOW, 1, 1, low[0]!["entry_id"] as string);
    const gapped = extendChain(W_HIGH, 1, 2, uuidv7()); // seq 3 over tip 1
    const res = await httpOn(LOG_ID, "POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: [...validExt, ...gapped],
    });
    const error = expectHttpError(res, 409, "writer_gap");
    expect(error.details).toEqual({
      writer_id: W_HIGH,
      expected_seq: 2,
      tip_entry_id: high[0]!["entry_id"],
    });

    const after = await onReplica(LOG_ID, ({ sql }) => ({
      counts: sql
        .exec("SELECT writer_id, COUNT(*) AS n FROM entries GROUP BY writer_id ORDER BY writer_id")
        .toArray(),
      tips: sql
        .exec("SELECT writer_id, last_seq, last_entry_id FROM writer_tips ORDER BY writer_id")
        .toArray(),
    }));
    expect(after).toEqual(before); // W_LOW's valid half was rolled back too
    await expectReplicaAuditClean(LOG_ID);
  });

  specTest(
    "§18.11 local arrival order may differ while frontiers and canonical entries converge",
    async () => {
      // Two replicas receive the SAME entries in different delivery orders
      // (one merge call per batch controls arrival_seq assignment).
      const chainA = makeChain(W_LOW, 3);
      const chainB = makeChain(W_HIGH, 3);
      await createReplica("r11-x");
      await createReplica("r11-y");

      // X: writers interleaved entry by entry.
      for (const e of [chainA[0], chainB[0], chainA[1], chainB[1], chainA[2], chainB[2]]) {
        await mergeInto("r11-x", [e!]);
      }
      // Y: all of B, then all of A.
      await mergeInto("r11-y", chainB);
      await mergeInto("r11-y", chainA);

      // Converged: identical frontiers and identical canonical byte sets.
      expect(await frontierOf("r11-y")).toEqual(await frontierOf("r11-x"));
      const setX = await entryByteSetOf("r11-x");
      expect(setX).toHaveLength(6);
      expect(await entryByteSetOf("r11-y")).toEqual(setX);

      // Non-vacuous divergence: the LOCAL arrival orders actually differ...
      const orderX = await arrivalOrderOf("r11-x");
      const orderY = await arrivalOrderOf("r11-y");
      expect(orderX).toEqual(
        [chainA[0], chainB[0], chainA[1], chainB[1], chainA[2], chainB[2]].map(
          (e) => e!["entry_id"],
        ),
      );
      expect(orderY).toEqual([...chainB, ...chainA].map((e) => e["entry_id"]));
      expect(orderX).not.toEqual(orderY);
      // ...over the same entry set.
      expect([...orderX].sort()).toEqual([...orderY].sort());
      await expectReplicaAuditClean("r11-x", "r11-y");
    },
  );

  specTest("§18.12 timestamps do not affect merge results", async () => {
    // Reading of §18.12 (recorded): created_at is advisory (§7) and clock
    // skew "cannot affect append position, frontier, merge, or conflict
    // handling" (§15.7). Entries differing only in created_at are DIFFERENT
    // entries (different canonical bytes), so the honest test is not
    // "swap timestamps, get the same entry" — it is that timestamp VALUES,
    // however skewed, never influence merge acceptance, entry order,
    // frontier positions, or conflict outcomes. A writer whose created_at
    // values run wildly backwards merges exactly like a well-clocked one:
    // positions come from writer_seq alone.
    const times: Record<number, string> = {
      1: "2030-01-01T00:00:00Z", // the FUTURE, at seq 1
      2: "1999-12-31T23:59:59Z",
      3: "2026-08-22T12:00:00Z",
      4: "1980-01-01T00:00:00Z", // the distant past, mid-chain
      5: "2005-06-15T08:30:00Z",
    };
    const chain = makeChain(W_LOW, 5, { createdAtFor: (seq) => times[seq]! });

    // Non-vacuity: timestamp order genuinely disagrees with writer_seq order.
    const byTime = chain
      .slice()
      .sort((a, b) => String(a["created_at"]).localeCompare(String(b["created_at"])))
      .map((e) => e["writer_seq"]);
    expect(byTime).toEqual([4, 2, 5, 3, 1]);
    expect(byTime).not.toEqual([1, 2, 3, 4, 5]);

    // Merged whole on P and split across two batches on Q: both accept
    // everything — no timestamp-based reordering or rejection.
    await createReplica("r12-p");
    await createReplica("r12-q");
    const whole = await mergeInto("r12-p", chain);
    expect(whole).toEqual({ inserted: 5, present: 0 });
    expect(await mergeInto("r12-q", chain.slice(0, 2))).toEqual({ inserted: 2, present: 0 });
    expect(await mergeInto("r12-q", chain.slice(2))).toEqual({ inserted: 3, present: 0 });

    // Frontier position is writer_seq 5 — whose created_at (2005) is neither
    // the newest nor the oldest timestamp in the chain.
    const expectedFrontier = [
      { writerId: W_LOW, seq: 5, entryId: chain[4]!["entry_id"] },
    ];
    expect(await frontierOf("r12-p")).toEqual(expectedFrontier);
    expect(await frontierOf("r12-q")).toEqual(expectedFrontier);
    expect(await entryByteSetOf("r12-q")).toEqual(await entryByteSetOf("r12-p"));

    // read_writer returns writer_seq order, NOT timestamp order.
    const page = await readWriterPage("r12-p", W_LOW, 0, null, 100);
    expect(page.entries.map((e) => e["writer_seq"])).toEqual([1, 2, 3, 4, 5]);

    // Conflict handling ignores time too: a rival at occupied seq 5 with a
    // strictly NEWER created_at is a writer_fork, never a timestamp winner.
    const rival = {
      version: 1,
      log_id: LOG_ID,
      entry_id: uuidv7(),
      writer_id: W_LOW,
      writer_seq: 5,
      prev_entry_id: chain[3]!["entry_id"],
      created_at: "2031-01-01T00:00:00Z",
      body: { pretender: true },
    };
    const error = await mergeErrorInto("r12-p", [rival]);
    expect(error).toEqual({ code: "writer_fork", details: { writerId: W_LOW, seq: 5 } });
    expect(await frontierOf("r12-p")).toEqual(expectedFrontier); // unchanged
    await expectReplicaAuditClean("r12-p", "r12-q");
  });
});

describe("suite anti-vacuity", () => {
  it("exactly 12 §18-numbered tests are registered in this file, covering items 1–12 once each", () => {
    expect(SPEC_TESTS).toHaveLength(12);
    const numbers = SPEC_TESTS.map((name) => {
      const match = /^§18\.(\d+) /.exec(name);
      expect(match, `test name lacks a §18.<n> prefix: ${name}`).not.toBeNull();
      return Number(match![1]);
    });
    expect([...numbers].sort((a, b) => a - b)).toEqual([1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  });
});

describe("the audit itself", () => {
  it("goes red on a corrupted store: a trigger-legal direct INSERT creates a gap, a stale tip, and a column/bytes mismatch, and the audit names each", async () => {
    // Fresh scratch replica; the pool's per-test isolated storage discards
    // the corruption afterwards, so no corrupt state outlives this test.
    const R = "audit-corrupt";
    await createReplica(R);
    const chain = makeChain(W_LOW, 2);
    await mergeInto(R, chain);

    // Positive control first: the audit is green on the known-good state.
    expect(await auditReplica(R)).toEqual([]);

    const violations = await onReplica(R, ({ sql, state }) => {
      // Bypass the store: direct INSERT at seq 4 (skipping 3 — a prefix
      // gap), leaving writer_tips stale at 2, with canonical_json bytes
      // whose writer_seq field says 9 (column/bytes disagreement). The
      // immutability triggers allow INSERT by design; only UPDATE/DELETE
      // are guarded — this is exactly the corruption they cannot catch.
      const rogueId = uuidv7();
      const lyingBytes = new TextEncoder().encode(
        JSON.stringify({
          version: 1,
          log_id: LOG_ID,
          entry_id: rogueId,
          writer_id: W_LOW,
          writer_seq: 9, // column below says 4
          prev_entry_id: null,
          created_at: CREATED_AT,
          body: {},
        }),
      );
      state.storage.transactionSync(() => {
        sql.exec(
          `INSERT INTO entries
             (entry_id, writer_id, writer_seq, prev_entry_id, created_at,
              canonical_json, received_at_ms)
           VALUES (?, ?, 4, ?, ?, ?, ?)`,
          rogueId,
          W_LOW,
          uuidv7(),
          CREATED_AT,
          lyingBytes.buffer.slice(0) as ArrayBuffer,
          Date.now(),
        );
      });
      return auditStore(sql);
    });

    // The audit fires, naming each corruption.
    expect(violations).not.toEqual([]);
    const rules = violations.map((v) => v.rule);
    expect(rules).toContain("prefix-complete"); // COUNT(*)=3 != MAX(writer_seq)=4
    expect(rules).toContain("tip-seq"); // writer_tips.last_seq=2 != MAX=4
    expect(rules).toContain("sequence-gap"); // 2 -> 4 jump in the chain walk
    expect(rules).toContain("column-bytes"); // column writer_seq=4, bytes say 9
    for (const violation of violations) {
      expect(violation.detail).toContain(W_LOW); // each names the writer
    }
  });
});

describe("restart durability (§15.2 / §8 invariant 2)", () => {
  it("acked entries survive a Durable Object restart; tips rebuild from SQL; the chain continues", async () => {
    // Mechanism note: @cloudflare/vitest-pool-workers 0.12.x exports no
    // evictDurableObject() — the documented equivalent used here is
    // DurableObjectState.abort(), which kills the live instance (workerd
    // re-instantiates on next access; storage survives). Per the
    // isolated-storage guidance, all storage work is flushed with
    // storage.sync() BEFORE the abort.
    const NAME = "restart";
    const id = env.COMMONPLACE_LOG.idFromName(NAME);

    // Phase 1: append + merge, ack observed, then flush storage. A marker
    // property on the live instance proves later that the instance was
    // genuinely replaced, not reused.
    const mergedChain = makeChain(W_HIGH, 2);
    const before = await runInDurableObject(
      env.COMMONPLACE_LOG.get(id),
      async (instance, state) => {
        (instance as { __liveMarker?: string }).__liveMarker = "pre-restart";
        const store = new LogStore(state.storage.sql, state.storage);
        store.createLog(LOG_ID);
        store.append(W_LOW, { n: 1 }, CREATED_AT);
        const appended = store.append(W_LOW, { n: 2 }, CREATED_AT);
        const merged = store.mergeEntries(mergedChain); // the ack
        expect(merged.inserted).toBe(2);
        await state.storage.sync(); // await storage promises before eviction
        return {
          frontier: store.frontier(),
          lastAppendedId: appended.entry.entryId,
          byteSet: state.storage.sql
            .exec("SELECT canonical_json FROM entries")
            .toArray()
            .map((r) => toHex(new Uint8Array(r.canonical_json as ArrayBuffer)))
            .sort(),
        };
      },
    );
    expect(before.byteSet).toHaveLength(4);

    // Phase 2: kill the object. abort() breaks the in-flight call — the
    // rejection IS the restart happening, so it is asserted, not swallowed.
    // Positive control first: the marker survives an un-aborted call boundary,
    // so phase 3's undefined-marker check demonstrates a fresh instance rather
    // than passing vacuously.
    await runInDurableObject(env.COMMONPLACE_LOG.get(id), (instance) => {
      expect((instance as { __liveMarker?: string }).__liveMarker).toBe("pre-restart");
    });
    await expect(
      runInDurableObject(env.COMMONPLACE_LOG.get(id), (_instance, state) => {
        state.abort("simulated restart");
      }),
    ).rejects.toThrow("simulated restart");

    // Phase 3: fresh stub, fresh instance. All correctness state must come
    // back from SQLite alone (the store keeps none in memory).
    await runInDurableObject(env.COMMONPLACE_LOG.get(id), (instance, state) => {
      // The instance is genuinely new: the marker died with the old one.
      expect((instance as { __liveMarker?: string }).__liveMarker).toBeUndefined();

      const store = new LogStore(state.storage.sql, state.storage);
      // Every acked entry is present, byte for byte.
      const byteSet = state.storage.sql
        .exec("SELECT canonical_json FROM entries")
        .toArray()
        .map((r) => toHex(new Uint8Array(r.canonical_json as ArrayBuffer)))
        .sort();
      expect(byteSet).toEqual(before.byteSet);
      // The frontier (tips rebuilt from SQL) is identical.
      expect(store.frontier()).toEqual(before.frontier);

      // A further append continues W_LOW's chain from the pre-restart tip.
      const next = store.append(W_LOW, { n: 3 }, CREATED_AT);
      expect(next.entry.writerSeq).toBe(3);
      expect(next.entry.prevEntryId).toBe(before.lastAppendedId);
      expectAuditClean(state.storage.sql);
    });
  });
});
