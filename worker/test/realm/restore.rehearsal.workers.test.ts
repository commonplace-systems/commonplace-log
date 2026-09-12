import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { RealmStore, type EntryRow, type TipRow } from "../../src/realm/store";

type Archive = {
  logId: string;
  entries: EntryRow[];
  tips: TipRow[];
};

type ComparableEntry = Omit<EntryRow, "canonicalBytes"> & { canonicalHex: string };

const encoder = new TextEncoder();
const decoder = new TextDecoder();

function textBytes(value: string): Uint8Array {
  return encoder.encode(value);
}

function hex(value: Uint8Array): string {
  return [...value].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

function canonicalBytes(entry: Omit<EntryRow, "canonicalBytes">, payload: string): Uint8Array {
  return textBytes(JSON.stringify({
    entry_id: entry.entryId,
    writer_id: entry.writerId,
    writer_seq: entry.writerSeq,
    prev_entry_id: entry.prevEntryId,
    created_at: entry.createdAt,
    payload,
  }));
}

function syntheticEntry(
  entryId: string,
  writerId: string,
  writerSeq: number,
  prevEntryId: string | null,
  payload: string,
): EntryRow {
  const metadata = {
    entryId,
    writerId,
    writerSeq,
    prevEntryId,
    createdAt: `2026-09-12T00:00:0${writerSeq}Z`,
  };
  return { ...metadata, canonicalBytes: canonicalBytes(metadata, payload) };
}

function expectedTips(entries: EntryRow[]): TipRow[] {
  const last = new Map<string, EntryRow>();
  for (const entry of entries) {
    const previous = last.get(entry.writerId);
    if (previous === undefined || entry.writerSeq > previous.writerSeq) last.set(entry.writerId, entry);
  }
  return [...last.values()]
    .sort((left, right) => left.writerId.localeCompare(right.writerId))
    .map((entry) => ({ writerId: entry.writerId, lastSeq: entry.writerSeq, lastEntryId: entry.entryId }));
}

/**
 * Fixture-only archive admission. RealmStore intentionally remains a low-level
 * indexed-byte store; this verifier is the explicit boundary a restore tool
 * would need before calling it.
 */
function verifyArchive(archive: Archive): void {
  if (archive.entries.length === 0) throw new Error("empty_archive");
  const ids = new Set<string>();
  const coordinates = new Set<string>();
  const byWriter = new Map<string, EntryRow[]>();

  for (const entry of archive.entries) {
    if (ids.has(entry.entryId)) throw new Error("duplicate_entry_id");
    ids.add(entry.entryId);
    const coordinate = `${entry.writerId}:${entry.writerSeq}`;
    if (coordinates.has(coordinate)) throw new Error("duplicate_writer_coordinate");
    coordinates.add(coordinate);

    let decoded: Record<string, unknown>;
    try {
      decoded = JSON.parse(decoder.decode(entry.canonicalBytes)) as Record<string, unknown>;
    } catch {
      throw new Error("invalid_canonical_json");
    }
    const expected = {
      entry_id: entry.entryId,
      writer_id: entry.writerId,
      writer_seq: entry.writerSeq,
      prev_entry_id: entry.prevEntryId,
      created_at: entry.createdAt,
    };
    for (const [key, value] of Object.entries(expected)) {
      if (decoded[key] !== value) throw new Error(`canonical_index_mismatch:${key}`);
    }

    const rows = byWriter.get(entry.writerId) ?? [];
    rows.push(entry);
    byWriter.set(entry.writerId, rows);
  }

  for (const rows of byWriter.values()) {
    rows.sort((left, right) => left.writerSeq - right.writerSeq);
    rows.forEach((entry, index) => {
      const expectedSeq = index + 1;
      const expectedPrev = index === 0 ? null : rows[index - 1]!.entryId;
      if (entry.writerSeq !== expectedSeq || entry.prevEntryId !== expectedPrev) {
        throw new Error("writer_chain_gap_or_fork");
      }
    });
  }

  expect(archive.tips).toEqual(expectedTips(archive.entries));
}

async function withNamedRealm<T>(
  name: string,
  fn: (store: RealmStore, state: DurableObjectState, instance: unknown) => T | Promise<T>,
): Promise<T> {
  const stub = env.REALM_CONTAINER.get(env.REALM_CONTAINER.idFromName(name));
  return await runInDurableObject(stub, (instance, state) =>
    fn(new RealmStore(state.storage.sql, state.storage), state, instance));
}

async function readArchive(name: string, logId: string): Promise<Archive> {
  return await withNamedRealm(name, (store, state) => {
    const rows = state.storage.sql
      .exec(
        `SELECT entry_id, writer_id, writer_seq, prev_entry_id, created_at, canonical_json
         FROM entries WHERE log_id = ? ORDER BY arrival_seq`,
        logId,
      )
      .toArray()
      .map((row) => ({
        entryId: String(row.entry_id),
        writerId: String(row.writer_id),
        writerSeq: Number(row.writer_seq),
        prevEntryId: row.prev_entry_id === null ? null : String(row.prev_entry_id),
        createdAt: String(row.created_at),
        canonicalBytes: new Uint8Array(row.canonical_json as ArrayBuffer),
      }));
    return {
      logId,
      entries: rows,
      tips: store.frontier(logId).writers.map((tip) => ({
        writerId: tip.writerId,
        lastSeq: tip.seq,
        lastEntryId: tip.entryId,
      })),
    };
  });
}

function comparable(archive: Archive): ComparableEntry[] {
  return archive.entries
    .map(({ canonicalBytes, ...entry }) => ({ ...entry, canonicalHex: hex(canonicalBytes) }))
    .sort((left, right) => `${left.writerId}:${left.writerSeq}`.localeCompare(`${right.writerId}:${right.writerSeq}`));
}

describe("local synthetic restore rehearsal", () => {
  it("replays two writers byte-for-byte, survives restart, and continues with fresh lease authority", async () => {
    const suffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const sourceName = `restore-source-${suffix}`;
    const targetName = `restore-target-${suffix}`;
    const logId = `restore-log-${suffix}`;
    const sourceEntries = [
      syntheticEntry("alpha-1", "writer-alpha", 1, null, "A1"),
      syntheticEntry("alpha-2", "writer-alpha", 2, "alpha-1", "A2"),
      syntheticEntry("beta-1", "writer-beta", 1, null, "B1"),
      syntheticEntry("beta-2", "writer-beta", 2, "beta-1", "B2"),
    ];
    const archive: Archive = { logId, entries: sourceEntries, tips: expectedTips(sourceEntries) };

    await withNamedRealm(sourceName, (store) => {
      store.createLog(logId, { createdAt: "2026-09-12T00:00:00Z" });
      expect(store.commit({
        logId,
        expectedRevision: 0,
        expectedEpoch: 0,
        insertEntries: sourceEntries,
        putTips: archive.tips,
      })).toBe(1);
    });
    const sourceArchive = await readArchive(sourceName, logId);
    expect(comparable(sourceArchive)).toEqual(comparable(archive));
    verifyArchive(sourceArchive);

    await withNamedRealm(targetName, (store) => store.createLog(logId, { createdAt: "2026-09-12T00:00:00Z" }));
    await withNamedRealm(targetName, (store) => {
      verifyArchive(sourceArchive);
      expect(store.commit({
        logId,
        expectedRevision: 0,
        expectedEpoch: 0,
        insertEntries: sourceArchive.entries,
        putTips: sourceArchive.tips,
      })).toBe(1);
      expect(store.frontier(logId)).toEqual({
        writers: sourceArchive.tips.map((tip) => ({ writerId: tip.writerId, seq: tip.lastSeq, entryId: tip.lastEntryId })),
      });
    });

    const beforeRestart = await readArchive(targetName, logId);
    await withNamedRealm(targetName, async (_store, state) => {
      await state.storage.sync();
    });
    await withNamedRealm(targetName, (_store, _state, instance) => {
      (instance as { __restoreMarker?: string }).__restoreMarker = "pre-restart";
    });
    await expect(withNamedRealm(targetName, async (_store, state, instance) => {
      expect((instance as { __restoreMarker?: string }).__restoreMarker).toBe("pre-restart");
      await state.storage.sync();
      state.abort("restore rehearsal restart");
    })).rejects.toThrow("restore rehearsal restart");

    await withNamedRealm(targetName, (_store, _state, instance) => {
      expect((instance as { __restoreMarker?: string }).__restoreMarker).toBeUndefined();
    });
    const afterRestart = await readArchive(targetName, logId);
    expect(comparable(afterRestart)).toEqual(comparable(beforeRestart));
    expect(afterRestart.tips).toEqual(beforeRestart.tips);

    const lease = await withNamedRealm(targetName, (store) => store.takeLease(logId));
    expect(lease.writerId).not.toMatch(/writer-(alpha|beta)/);
    await withNamedRealm(targetName, (store) => {
      const live = syntheticEntry("live-1", lease.writerId, 1, null, "new-live-entry");
      expect(store.commit({
        logId,
        expectedRevision: 1,
        expectedEpoch: lease.leaseEpoch,
        insertEntries: [live],
        putTips: [{ writerId: lease.writerId, lastSeq: 1, lastEntryId: live.entryId }],
      })).toBe(2);
    });
    const continued = await readArchive(targetName, logId);
    expect(comparable(continued).filter((entry) => entry.writerId.startsWith("writer-"))).toEqual(comparable(beforeRestart));
    expect(continued.tips).toContainEqual({ writerId: lease.writerId, lastSeq: 1, lastEntryId: "live-1" });
  });

  it("rejects canonical/index disagreement before the empty target receives a write", async () => {
    const suffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const targetName = `restore-negative-${suffix}`;
    const logId = `restore-negative-log-${suffix}`;
    const valid = syntheticEntry("alpha-1", "writer-alpha", 1, null, "A1");
    const malformed: Archive = {
      logId,
      entries: [{ ...valid, writerSeq: 2 }],
      tips: [{ writerId: "writer-alpha", lastSeq: 2, lastEntryId: "alpha-1" }],
    };

    await withNamedRealm(targetName, (store) => store.createLog(logId));
    expect(() => verifyArchive(malformed)).toThrow("canonical_index_mismatch:writer_seq");
    const empty = await readArchive(targetName, logId);
    expect(empty.entries).toEqual([]);
    expect(empty.tips).toEqual([]);
  });
});
