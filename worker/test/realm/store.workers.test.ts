import { describe, expect, it } from "vitest";
import { RealmStoreError, type CommitPlan } from "../../src/realm/store";
import { bytes, caught, decoded, withRealm } from "./helpers";

const A = "log-a";
const B = "log-b";
const W1 = "writer-1";
const W2 = "writer-2";

function plan(logId: string, revision: number, epoch: number, suffix: string, writerId = W1): CommitPlan {
  return {
    logId,
    expectedRevision: revision,
    expectedEpoch: epoch,
    insertEntries: [{
      entryId: `entry-${suffix}`, writerId, writerSeq: 1, prevEntryId: null,
      createdAt: "2026-08-23T00:00:00Z", canonicalBytes: bytes(`bytes-${suffix}`), receivedAtMs: 1,
    }],
    putTips: [{ writerId, lastSeq: 1, lastEntryId: `entry-${suffix}` }],
  };
}

function code(error: unknown): string | undefined {
  return error instanceof RealmStoreError ? error.code : undefined;
}

describe("realm store", () => {
  it("creates many idempotent logs in one database", async () => {
    await withRealm((sql, store) => {
      store.createLog(A, { formatVersion: 1, createdAt: "a-time" });
      store.createLog(B, { formatVersion: 1, createdAt: "b-time" });
      store.createLog(A, { formatVersion: 1, createdAt: "ignored" });
      expect(sql.exec("SELECT log_id, revision, lease_epoch FROM logs ORDER BY log_id").toArray())
        .toEqual([{ log_id: A, revision: 0, lease_epoch: 0 }, { log_id: B, revision: 0, lease_epoch: 0 }]);
    });
  });

  it("reads never create: all stored SQLite state is byte-for-byte unchanged", async () => {
    await withRealm((sql, store) => {
      const before = JSON.stringify(sql.exec("SELECT name, type, sql FROM sqlite_master ORDER BY name").toArray());
      expect(code(caught(() => store.readSet("missing", { writers: [], coordinates: [], entryIds: [] })))).toBe("not_found");
      expect(code(caught(() => store.frontier("missing")))).toBe("not_found");
      expect(code(caught(() => store.readWriter("missing", W1, { afterSeq: 0, limit: 10 })))).toBe("not_found");
      expect(code(caught(() => store.tailLocal("missing", { afterArrival: 0, limit: 10 })))).toBe("not_found");
      const after = JSON.stringify(sql.exec("SELECT name, type, sql FROM sqlite_master ORDER BY name").toArray());
      expect(after).toBe(before);
    });
  });

  it("takes monotonically increasing writer leases", async () => {
    await withRealm((_sql, store) => {
      store.createLog(A);
      expect(store.takeLease(A)).toBe(1);
      expect(store.takeLease(A)).toBe(2);
      expect(store.readSet(A, { writers: [], coordinates: [], entryIds: [] }).leaseEpoch).toBe(2);
    });
  });

  it("current revision commits atomically and stale_revision writes nothing", async () => {
    await withRealm((sql, store) => {
      store.createLog(A);
      expect(store.commit(plan(A, 0, 0, "one"))).toBe(1);
      const snapshot = JSON.stringify({
        logs: sql.exec("SELECT * FROM logs").toArray(), entries: sql.exec("SELECT * FROM entries").toArray(),
        tips: sql.exec("SELECT * FROM writer_tips").toArray(),
      });
      expect(code(caught(() => store.commit(plan(A, 0, 0, "stale", W2))))).toBe("stale_revision");
      expect(JSON.stringify({
        logs: sql.exec("SELECT * FROM logs").toArray(), entries: sql.exec("SELECT * FROM entries").toArray(),
        tips: sql.exec("SELECT * FROM writer_tips").toArray(),
      })).toBe(snapshot);
    });
  });

  it("obsolete_epoch is distinct from stale_revision and writes nothing", async () => {
    await withRealm((sql, store) => {
      store.createLog(A);
      const epoch = store.takeLease(A);
      expect(epoch).toBe(1);
      const before = JSON.stringify({
        log: sql.exec("SELECT revision, lease_epoch FROM logs WHERE log_id = ?", A).one(),
        entries: sql.exec("SELECT * FROM entries WHERE log_id = ?", A).toArray(),
        tips: sql.exec("SELECT * FROM writer_tips WHERE log_id = ?", A).toArray(),
      });
      expect(code(caught(() => store.commit(plan(A, 0, 0, "old"))))).toBe("obsolete_epoch");
      expect(JSON.stringify({
        log: sql.exec("SELECT revision, lease_epoch FROM logs WHERE log_id = ?", A).one(),
        entries: sql.exec("SELECT * FROM entries WHERE log_id = ?", A).toArray(),
        tips: sql.exec("SELECT * FROM writer_tips WHERE log_id = ?", A).toArray(),
      })).toBe(before);
      expect(store.commit(plan(A, 0, 1, "current"))).toBe(1);
    });
  });

  it("returns one coherent read-set with its exact shape", async () => {
    await withRealm((_sql, store) => {
      store.createLog(A);
      store.commit(plan(A, 0, 0, "one"));
      expect(store.readSet(A, {
        writers: [W1], coordinates: [{ writerId: W1, writerSeq: 1 }], entryIds: ["entry-one"],
      })).toEqual({
        logId: A, formatVersion: 1, revision: 1, leaseEpoch: 0,
        tips: [{ writerId: W1, lastSeq: 1, lastEntryId: "entry-one" }],
        coordinates: [{ writerId: W1, writerSeq: 1, canonicalBytes: bytes("bytes-one") }],
        entryIds: [{ entryId: "entry-one", canonicalBytes: bytes("bytes-one") }],
      });
    });
  });

  it("isolates two logs across metadata, entries, tips, frontier, and reads", async () => {
    await withRealm((sql, store) => {
      store.createLog(A); store.createLog(B);
      const bEpoch = store.takeLease(B);
      store.commit(plan(B, 0, bEpoch, "b"));
      const beforeB = JSON.stringify({
        log: sql.exec("SELECT revision, lease_epoch FROM logs WHERE log_id = ?", B).one(),
        entries: sql.exec("SELECT entry_id, writer_id, writer_seq FROM entries WHERE log_id = ?", B).toArray(),
        tips: sql.exec("SELECT * FROM writer_tips WHERE log_id = ?", B).toArray(),
        frontier: store.frontier(B),
      });
      store.commit(plan(A, 0, 0, "a"));
      expect(JSON.stringify({
        log: sql.exec("SELECT revision, lease_epoch FROM logs WHERE log_id = ?", B).one(),
        entries: sql.exec("SELECT entry_id, writer_id, writer_seq FROM entries WHERE log_id = ?", B).toArray(),
        tips: sql.exec("SELECT * FROM writer_tips WHERE log_id = ?", B).toArray(),
        frontier: store.frontier(B),
      })).toBe(beforeB);
      const aRead = store.readSet(A, {
        writers: [W1], coordinates: [{ writerId: W1, writerSeq: 1 }], entryIds: ["entry-a", "entry-b"],
      });
      expect(aRead.tips.map((tip) => tip.lastEntryId)).toEqual(["entry-a"]);
      expect(aRead.coordinates.map((entry) => decoded(entry.canonicalBytes))).toEqual(["bytes-a"]);
      expect(aRead.entryIds.map((entry) => entry.entryId)).toEqual(["entry-a"]);
      expect(store.frontier(A)).toEqual({ writers: [{ writerId: W1, seq: 1, entryId: "entry-a" }] });
      expect(store.readWriter(A, W1, { afterSeq: 0, limit: 10 }).entries.map((entry) => decoded(entry.canonicalBytes)))
        .toEqual(["bytes-a"]);
      expect(store.tailLocal(A, { afterArrival: 0, limit: 10 }).entries.map((entry) => decoded(entry.canonicalBytes)))
        .toEqual(["bytes-a"]);
    });
  });

  it("reports SQLite constraint failures as storage facts and rolls back", async () => {
    await withRealm((sql, store) => {
      store.createLog(A);
      const bad = plan(A, 0, 0, "bad");
      bad.insertEntries.push({ ...bad.insertEntries[0]!, canonicalBytes: bytes("different") });
      expect(code(caught(() => store.commit(bad)))).toBe("constraint");
      expect(sql.exec("SELECT COUNT(*) AS n FROM entries WHERE log_id = ?", A).one().n).toBe(0);
      expect(sql.exec("SELECT COUNT(*) AS n FROM writer_tips WHERE log_id = ?", A).one().n).toBe(0);
      expect(sql.exec("SELECT revision FROM logs WHERE log_id = ?", A).one().revision).toBe(0);
    });
  });

  it("pins read_writer continuation cursor and throughSeq clamp", async () => {
    await withRealm((_sql, store) => {
      store.createLog(A);
      const entries = [1, 2, 3].map((n) => ({ entryId: `e${n}`, writerId: W1, writerSeq: n,
        prevEntryId: n === 1 ? null : `e${n - 1}`, createdAt: "now", canonicalBytes: bytes(`b${n}`), receivedAtMs: n }));
      store.commit({ logId: A, expectedRevision: 0, expectedEpoch: 0, insertEntries: entries,
        putTips: [{ writerId: W1, lastSeq: 3, lastEntryId: "e3" }] });
      const first = store.readWriter(A, W1, { afterSeq: 0, throughSeq: 3, limit: 2 });
      expect(first.entries.map((entry) => [decoded(entry.canonicalBytes), entry.writerSeq])).toEqual([["b1", 1], ["b2", 2]]);
      expect(first.nextAfterSeq).toBe(2);
      const last = store.readWriter(A, W1, { afterSeq: 2, throughSeq: 3, limit: 2 });
      expect(last.entries.map((entry) => entry.writerSeq)).toEqual([3]);
      expect(last.nextAfterSeq).toBeNull();
    });
  });

  it("pins tail_local continuation cursor in realm arrival order", async () => {
    await withRealm((_sql, store) => {
      store.createLog(A);
      const entries = [1, 2, 3].map((n) => ({ entryId: `e${n}`, writerId: W1, writerSeq: n,
        prevEntryId: n === 1 ? null : `e${n - 1}`, createdAt: "now", canonicalBytes: bytes(`b${n}`), receivedAtMs: n }));
      store.commit({ logId: A, expectedRevision: 0, expectedEpoch: 0, insertEntries: entries,
        putTips: [{ writerId: W1, lastSeq: 3, lastEntryId: "e3" }] });
      const first = store.tailLocal(A, { afterArrival: 0, limit: 2 });
      expect(first.entries.map((entry) => decoded(entry.canonicalBytes))).toEqual(["b1", "b2"]);
      expect(first.nextAfterArrival).toBe(first.entries[1]!.arrivalSeq);
      const last = store.tailLocal(A, { afterArrival: first.nextAfterArrival!, limit: 2 });
      expect(last.entries.map((entry) => decoded(entry.canonicalBytes))).toEqual(["b3"]);
      expect(last.nextAfterArrival).toBeNull();
    });
  });
});
