import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { validateEntry } from "../../src/entry";
import { canonicalize } from "../../src/jcs";
import { RealmStore, type EntryRow, type TipRow } from "../../src/realm/store";

type Archive = { logId: string; entries: EntryRow[]; tips: TipRow[] };
type ImportResult = { imported: number; skipped: number };

class RestoreArchiveError extends Error {
  constructor(readonly reason: string) {
    super(reason);
    this.name = "RestoreArchiveError";
  }
}

const encoder = new TextEncoder();
const decoder = new TextDecoder();
const LOG_ID = "10000000-0000-4000-8000-000000000001";
const W_ALPHA = "10000000-0000-4000-8000-000000000002";
const W_BETA = "10000000-0000-4000-8000-000000000003";
const W_UNRELATED = "10000000-0000-4000-8000-000000000004";

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  return left.byteLength === right.byteLength && left.every((byte, index) => byte === right[index]);
}

function entry(
  entryId: string,
  writerId: string,
  writerSeq: number,
  prevEntryId: string | null,
  body: string,
): EntryRow {
  const value = {
    version: 1,
    log_id: LOG_ID,
    entry_id: entryId,
    writer_id: writerId,
    writer_seq: writerSeq,
    prev_entry_id: prevEntryId,
    created_at: "2026-09-12T00:00:00Z",
    body: { rehearsal: body },
  };
  return {
    entryId,
    writerId,
    writerSeq,
    prevEntryId,
    createdAt: value.created_at,
    canonicalBytes: canonicalize(value),
  };
}

function expectedTips(entries: EntryRow[]): TipRow[] {
  const last = new Map<string, EntryRow>();
  for (const current of entries) {
    const prior = last.get(current.writerId);
    if (prior === undefined || current.writerSeq > prior.writerSeq) last.set(current.writerId, current);
  }
  return [...last.values()]
    .sort((left, right) => left.writerId.localeCompare(right.writerId))
    .map((current) => ({
      writerId: current.writerId,
      lastSeq: current.writerSeq,
      lastEntryId: current.entryId,
    }));
}

function asRecord(bytes: Uint8Array): Record<string, unknown> {
  try {
    const parsed: unknown = JSON.parse(decoder.decode(bytes));
    if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
      throw new RestoreArchiveError("canonical_not_object");
    }
    return parsed as Record<string, unknown>;
  } catch (error) {
    if (error instanceof RestoreArchiveError) throw error;
    throw new RestoreArchiveError("canonical_not_json");
  }
}

function assertCanonicalRow(logId: string, row: EntryRow): void {
  const checked = validateEntry(row.canonicalBytes);
  if (!checked.ok) throw new RestoreArchiveError(`invalid_entry:${checked.reason}`);
  // validateEntry canonicalizes parsed JSON; exact equality is the archive
  // boundary, so duplicate keys/non-canonical whitespace cannot pass through.
  if (!sameBytes(checked.canonicalBytes, row.canonicalBytes)) {
    throw new RestoreArchiveError("canonical_bytes_not_jcs");
  }
  const parsed = asRecord(row.canonicalBytes);
  const expected: Record<string, unknown> = {
    log_id: logId,
    entry_id: row.entryId,
    writer_id: row.writerId,
    writer_seq: row.writerSeq,
    prev_entry_id: row.prevEntryId,
    created_at: row.createdAt,
  };
  for (const [key, value] of Object.entries(expected)) {
    if (parsed[key] !== value) throw new RestoreArchiveError(`canonical_index_mismatch:${key}`);
  }
}

function validateArchive(archive: Archive): void {
  if (archive.entries.length === 0) throw new RestoreArchiveError("empty_archive");
  const ids = new Set<string>();
  const coordinates = new Set<string>();
  const byWriter = new Map<string, EntryRow[]>();
  for (const row of archive.entries) {
    if (ids.has(row.entryId)) throw new RestoreArchiveError("duplicate_entry_id");
    ids.add(row.entryId);
    const coordinate = `${row.writerId}:${row.writerSeq}`;
    if (coordinates.has(coordinate)) throw new RestoreArchiveError("duplicate_writer_coordinate");
    coordinates.add(coordinate);
    assertCanonicalRow(archive.logId, row);
    const rows = byWriter.get(row.writerId) ?? [];
    rows.push(row);
    byWriter.set(row.writerId, rows);
  }

  for (const rows of byWriter.values()) {
    rows.sort((left, right) => left.writerSeq - right.writerSeq);
    rows.forEach((row, index) => {
      if (row.writerSeq !== index + 1) throw new RestoreArchiveError("writer_sequence_gap");
      const expectedPrevious = index === 0 ? null : rows[index - 1]!.entryId;
      if (row.prevEntryId !== expectedPrevious) throw new RestoreArchiveError("writer_predecessor_mismatch");
    });
  }

  const seenTips = new Set<string>();
  for (const tip of archive.tips) {
    if (seenTips.has(tip.writerId)) throw new RestoreArchiveError("duplicate_tip");
    seenTips.add(tip.writerId);
  }
  if (JSON.stringify(archive.tips) !== JSON.stringify(expectedTips(archive.entries))) {
    throw new RestoreArchiveError("frontier_tip_mismatch");
  }
}

/** Export only through the real read surfaces used by a restore coordinator. */
function exportArchive(store: RealmStore, logId: string): Archive {
  const frontier = store.frontier(logId);
  const entries: EntryRow[] = [];
  for (const writer of frontier.writers) {
    let afterSeq = 0;
    while (true) {
      const page = store.readWriter(logId, writer.writerId, { afterSeq, throughSeq: writer.seq, limit: 2 });
      for (const item of page.entries) {
        const parsed = asRecord(item.canonicalBytes);
        entries.push({
          entryId: String(parsed.entry_id),
          writerId: String(parsed.writer_id),
          writerSeq: item.writerSeq,
          prevEntryId: parsed.prev_entry_id === null ? null : String(parsed.prev_entry_id),
          createdAt: String(parsed.created_at),
          canonicalBytes: item.canonicalBytes,
        });
      }
      if (page.nextAfterSeq === null) break;
      afterSeq = page.nextAfterSeq;
    }
  }
  const archive = {
    logId,
    entries,
    tips: frontier.writers.map((writer) => ({
      writerId: writer.writerId,
      lastSeq: writer.seq,
      lastEntryId: writer.entryId,
    })),
  };
  validateArchive(archive);
  return archive;
}

async function withRealm<T>(name: string, fn: (store: RealmStore, state: DurableObjectState) => T | Promise<T>): Promise<T> {
  const stub = env.REALM_CONTAINER.get(env.REALM_CONTAINER.idFromName(name));
  return await runInDurableObject(stub, (_instance, state) =>
    fn(new RealmStore(state.storage.sql, state.storage), state));
}

function coordinate(row: EntryRow): string {
  return `${row.writerId}:${row.writerSeq}`;
}

/**
 * Test-only resumable importer. It never calls commit until every existing
 * identity/coordinate has been compared with the incoming canonical bytes.
 */
function importArchive(store: RealmStore, archive: Archive, maxEntries?: number): ImportResult {
  validateArchive(archive);
  const archiveWriters = new Set(archive.tips.map((tip) => tip.writerId));
  for (const targetWriter of store.frontier(archive.logId).writers) {
    if (!archiveWriters.has(targetWriter.writerId)) {
      throw new RestoreArchiveError("target_has_unlisted_writer");
    }
  }
  const query = store.readSet(archive.logId, {
    writers: [...new Set(archive.entries.map((row) => row.writerId))],
    coordinates: archive.entries.map((row) => ({ writerId: row.writerId, writerSeq: row.writerSeq })),
    entryIds: archive.entries.map((row) => row.entryId),
  });
  const byCoordinate = new Map(query.coordinates.map((row) => [`${row.writerId}:${row.writerSeq}`, row.canonicalBytes]));
  const byId = new Map(query.entryIds.map((row) => [row.entryId, row.canonicalBytes]));
  const tips = new Map(query.tips.map((tip) => [tip.writerId, tip]));

  for (const writerTip of query.tips) {
    const sourceTip = archive.tips.find((tip) => tip.writerId === writerTip.writerId);
    if (sourceTip === undefined || writerTip.lastSeq > sourceTip.lastSeq) {
      throw new RestoreArchiveError("target_tip_ahead_of_archive");
    }
    const sourceAtTip = archive.entries.find((row) =>
      row.writerId === writerTip.writerId && row.writerSeq === writerTip.lastSeq);
    if (sourceAtTip === undefined || sourceAtTip.entryId !== writerTip.lastEntryId) {
      throw new RestoreArchiveError("target_tip_diverges");
    }
  }

  const missing: EntryRow[] = [];
  let skipped = 0;
  for (const row of archive.entries) {
    const existingByCoordinate = byCoordinate.get(coordinate(row));
    const existingById = byId.get(row.entryId);
    if (existingByCoordinate !== undefined || existingById !== undefined) {
      if (existingByCoordinate === undefined || existingById === undefined) {
        throw new RestoreArchiveError("partial_target_identity");
      }
      if (!sameBytes(existingByCoordinate, row.canonicalBytes) || !sameBytes(existingById, row.canonicalBytes)) {
        throw new RestoreArchiveError("existing_identity_conflict");
      }
      skipped += 1;
    } else {
      missing.push(row);
    }
  }
  // A resumable checkpoint is independent of archive arrival order. Always
  // consume a deterministic writer/sequence prefix for bounded batches.
  const orderedMissing = [...missing].sort((left, right) =>
    left.writerId.localeCompare(right.writerId) || left.writerSeq - right.writerSeq);
  const batch = maxEntries === undefined ? orderedMissing : orderedMissing.slice(0, maxEntries);
  if (batch.length === 0) return { imported: 0, skipped };

  const putTips = expectedTips(batch).map((tip) => {
    const current = tips.get(tip.writerId);
    if (current !== undefined && current.lastSeq > tip.lastSeq) {
      throw new RestoreArchiveError("batch_would_move_tip_backwards");
    }
    return tip;
  });
  store.commit({
    logId: archive.logId,
    expectedRevision: query.revision,
    expectedEpoch: query.leaseEpoch,
    insertEntries: batch,
    putTips,
  });
  return { imported: batch.length, skipped };
}

function rows(): EntryRow[] {
  return [
    entry("10000000-0000-4000-8000-000000000010", W_ALPHA, 1, null, "alpha-1"),
    entry("10000000-0000-4000-8000-000000000011", W_ALPHA, 2, "10000000-0000-4000-8000-000000000010", "alpha-2"),
    entry("10000000-0000-4000-8000-000000000012", W_BETA, 1, null, "beta-1"),
    entry("10000000-0000-4000-8000-000000000013", W_BETA, 2, "10000000-0000-4000-8000-000000000012", "beta-2"),
  ];
}

describe("validated resumable archive import rehearsal", () => {
  it("exports real canonical rows through frontier/readWriter and resumes only missing rows", async () => {
    const suffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const sourceName = `archive-source-${suffix}`;
    const targetName = `archive-target-${suffix}`;
    const sourceRows = rows();
    const sourceArchive: Archive = { logId: LOG_ID, entries: sourceRows, tips: expectedTips(sourceRows) };

    await withRealm(sourceName, (store) => {
      store.createLog(LOG_ID);
      store.commit({ logId: LOG_ID, expectedRevision: 0, expectedEpoch: 0, insertEntries: sourceRows, putTips: sourceArchive.tips });
      expect(exportArchive(store, LOG_ID)).toEqual(sourceArchive);
    });
    await withRealm(targetName, (store) => store.createLog(LOG_ID));

    const first = await withRealm(targetName, (store) => {
      store.takeLease(LOG_ID);
      return importArchive(store, sourceArchive, 2);
    });
    expect(first).toEqual({ imported: 2, skipped: 0 });
    const second = await withRealm(targetName, (store) => {
      store.takeLease(LOG_ID);
      const shuffled: Archive = {
        ...sourceArchive,
        entries: [sourceRows[2]!, sourceRows[0]!, sourceRows[3]!, sourceRows[1]!],
      };
      return importArchive(store, shuffled);
    });
    expect(second).toEqual({ imported: 2, skipped: 2 });
    const duplicate = await withRealm(targetName, (store) => importArchive(store, sourceArchive));
    expect(duplicate).toEqual({ imported: 0, skipped: 4 });
    await withRealm(targetName, (store) => {
      const query = {
        writers: [W_ALPHA, W_BETA],
        coordinates: sourceRows.map((row) => ({ writerId: row.writerId, writerSeq: row.writerSeq })),
        entryIds: sourceRows.map((row) => row.entryId),
      };
      const before = store.readSet(LOG_ID, query);
      expect(importArchive(store, sourceArchive)).toEqual({ imported: 0, skipped: 4 });
      const after = store.readSet(LOG_ID, query);
      expect(after.revision).toBe(before.revision);
    });
    await withRealm(targetName, (store) => {
      expect(exportArchive(store, LOG_ID)).toEqual(sourceArchive);
    });
  });

  it("rejects malformed canonical, chain, and tip archives before any target mutation", async () => {
    const suffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const targetName = `archive-invalid-${suffix}`;
    const validRows = rows();
    const valid: Archive = { logId: LOG_ID, entries: validRows, tips: expectedTips(validRows) };
    await withRealm(targetName, (store) => store.createLog(LOG_ID));

    const malformedCanonical: Archive = {
      ...valid,
      entries: [{ ...validRows[0]!, canonicalBytes: encoder.encode("not-json") }, ...validRows.slice(1)],
    };
    const gapRow = entry(validRows[1]!.entryId, W_ALPHA, 3, validRows[0]!.entryId, "alpha-gap");
    const gap: Archive = {
      ...valid,
      entries: [validRows[0]!, gapRow, validRows[2]!, validRows[3]!],
    };
    const wrongTips: Archive = {
      ...valid,
      tips: valid.tips.map((tip) => tip.writerId === W_BETA ? { ...tip, lastSeq: 1 } : tip),
    };
    for (const invalid of [malformedCanonical, gap, wrongTips]) {
      await withRealm(targetName, (store) => {
        const before = store.readSet(LOG_ID, { writers: [W_ALPHA, W_BETA], coordinates: [], entryIds: [] });
        if (invalid === gap) {
          expect(() => importArchive(store, invalid)).toThrow("writer_sequence_gap");
        } else {
          expect(() => importArchive(store, invalid)).toThrow(RestoreArchiveError);
        }
        const after = store.readSet(LOG_ID, { writers: [W_ALPHA, W_BETA], coordinates: [], entryIds: [] });
        expect(after).toEqual(before);
      });
    }
  });

  it("refuses a same-coordinate and same-ID byte conflict before mutation", async () => {
    const suffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const targetName = `archive-conflict-${suffix}`;
    const sourceRows = rows();
    const valid: Archive = { logId: LOG_ID, entries: sourceRows, tips: expectedTips(sourceRows) };
    await withRealm(targetName, (store) => {
      store.createLog(LOG_ID);
      store.commit({ logId: LOG_ID, expectedRevision: 0, expectedEpoch: 0, insertEntries: sourceRows, putTips: valid.tips });
    });
    const original = sourceRows[0]!;
    const changedValue = {
      version: 1,
      log_id: LOG_ID,
      entry_id: original.entryId,
      writer_id: original.writerId,
      writer_seq: original.writerSeq,
      prev_entry_id: original.prevEntryId,
      created_at: original.createdAt,
      body: { rehearsal: "different-bytes" },
    };
    const conflicting: Archive = {
      ...valid,
      entries: [{ ...original, canonicalBytes: canonicalize(changedValue) }, ...sourceRows.slice(1)],
    };
    await withRealm(targetName, (store) => {
      const before = store.readSet(LOG_ID, {
        writers: [W_ALPHA, W_BETA],
        coordinates: sourceRows.map((row) => ({ writerId: row.writerId, writerSeq: row.writerSeq })),
        entryIds: sourceRows.map((row) => row.entryId),
      });
      expect(() => importArchive(store, conflicting)).toThrow("existing_identity_conflict");
      const after = store.readSet(LOG_ID, {
        writers: [W_ALPHA, W_BETA],
        coordinates: sourceRows.map((row) => ({ writerId: row.writerId, writerSeq: row.writerSeq })),
        entryIds: sourceRows.map((row) => row.entryId),
      });
      expect(after).toEqual(before);
    });
  });

  it("refuses a target log with an unrelated writer before mutation", async () => {
    const suffix = `${Date.now()}-${Math.random().toString(16).slice(2)}`;
    const targetName = `archive-unrelated-${suffix}`;
    const sourceRows = rows();
    const valid: Archive = { logId: LOG_ID, entries: sourceRows, tips: expectedTips(sourceRows) };
    const unrelated = entry("10000000-0000-4000-8000-000000000020", W_UNRELATED, 1, null, "unrelated");
    await withRealm(targetName, (store) => {
      store.createLog(LOG_ID);
      store.commit({ logId: LOG_ID, expectedRevision: 0, expectedEpoch: 0, insertEntries: [unrelated], putTips: [
        { writerId: W_UNRELATED, lastSeq: 1, lastEntryId: unrelated.entryId },
      ] });
    });
    await withRealm(targetName, (store) => {
      const before = store.readSet(LOG_ID, {
        writers: [W_UNRELATED],
        coordinates: [{ writerId: W_UNRELATED, writerSeq: 1 }],
        entryIds: [unrelated.entryId],
      });
      expect(() => importArchive(store, valid)).toThrow("target_has_unlisted_writer");
      const after = store.readSet(LOG_ID, {
        writers: [W_UNRELATED],
        coordinates: [{ writerId: W_UNRELATED, writerSeq: 1 }],
        entryIds: [unrelated.entryId],
      });
      expect(after).toEqual(before);
    });
  });
});
