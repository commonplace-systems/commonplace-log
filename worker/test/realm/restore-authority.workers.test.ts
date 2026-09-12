import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { canonicalize } from "../../src/jcs";
import { RealmStore, RealmStoreError, type EntryRow, type RestoreArchive } from "../../src/realm/store";

const LOG = "10000000-0000-4000-8000-000000000101";
const WRITER = "10000000-0000-4000-8000-000000000102";

function row(id: string, seq: number, previous: string | null, body: string): EntryRow {
  const value = {
    version: 1,
    log_id: LOG,
    entry_id: id,
    writer_id: WRITER,
    writer_seq: seq,
    prev_entry_id: previous,
    created_at: "2026-09-12T00:00:00Z",
    body: { rehearsal: body },
  };
  return {
    entryId: id,
    writerId: WRITER,
    writerSeq: seq,
    prevEntryId: previous,
    createdAt: value.created_at,
    canonicalBytes: canonicalize(value),
  };
}

function archive(): RestoreArchive {
  const first = row("10000000-0000-4000-8000-000000000103", 1, null, "one");
  const second = row("10000000-0000-4000-8000-000000000104", 2, first.entryId, "two");
  return { logId: LOG, archiveId: "archive-101", writerId: WRITER, entries: [first, second] };
}

async function withRealm<T>(name: string, fn: (store: RealmStore, state: DurableObjectState) => T | Promise<T>): Promise<T> {
  const stub = env.REALM_CONTAINER.get(env.REALM_CONTAINER.idFromName(name));
  return await runInDurableObject(stub, (_instance, state) => fn(new RealmStore(state.storage.sql, state.storage), state));
}

async function snapshot(name: string): Promise<string> {
  return await withRealm(name, (_store, state) => JSON.stringify({
    entries: state.storage.sql.exec("SELECT entry_id, writer_id, writer_seq, prev_entry_id, canonical_json FROM entries WHERE log_id = ? ORDER BY writer_seq", LOG).toArray().map((row) => ({
      ...row,
      canonical_json: Array.from(new Uint8Array(row.canonical_json as ArrayBuffer)),
    })),
    tips: state.storage.sql.exec("SELECT writer_id, last_seq, last_entry_id FROM writer_tips WHERE log_id = ?", LOG).toArray(),
    marker: state.storage.sql.exec("SELECT archive_id, writer_id, entry_count, total_bytes, manifest_json, state FROM restore_markers WHERE log_id = ?", LOG).toArray().map((row) => ({
      ...row,
      manifest_json: Array.from(new Uint8Array(row.manifest_json as ArrayBuffer)),
    })),
  }));
}

describe("internal restore binding", () => {
  it("preserves the historical writer, fences pending operations, resumes durably, and leases fresh authority", async () => {
    const name = `restore-binding-${Date.now()}-${Math.random()}`;
    const source = archive();
    const first = await withRealm(name, (store) => store.restoreBatch(source, 1));
    expect(first).toEqual({ imported: 1, skipped: 0, complete: false });
    await expect(withRealm(name, async (_store, state) => {
      await state.storage.sync();
      state.abort("restore binding pending restart");
    })).rejects.toThrow("restore binding pending restart");
    await withRealm(name, (store) => {
      expect(() => store.frontier(LOG)).toThrow(RealmStoreError);
      expect(() => store.takeLease(LOG)).toThrow(RealmStoreError);
    });
    const second = await withRealm(name, (store) => store.restoreBatch(source));
    expect(second).toEqual({ imported: 1, skipped: 1, complete: true });
    await expect(withRealm(name, async (_store, state) => {
      await state.storage.sync();
      state.abort("restore binding restart");
    })).rejects.toThrow("restore binding restart");
    const repeated = await withRealm(name, (store) => store.restoreBatch(source));
    expect(repeated).toEqual({ imported: 0, skipped: 2, complete: true });
    const lease = await withRealm(name, (store) => store.takeLease(LOG));
    expect(lease.writerId).toBe(WRITER);
    const nextLease = await withRealm(name, (store) => store.takeLease(LOG));
    expect(nextLease.writerId).toBe(WRITER);
    const live = row("10000000-0000-4000-8000-000000000106", 3, "10000000-0000-4000-8000-000000000104", "three");
    await withRealm(name, (store) => {
      expect(() => store.commit({
        logId: LOG,
        expectedRevision: 2,
        expectedEpoch: lease.leaseEpoch,
        insertEntries: [live],
        putTips: [{ writerId: WRITER, lastSeq: 3, lastEntryId: live.entryId }],
      })).toThrow(RealmStoreError);
      expect(store.commit({
        logId: LOG,
        expectedRevision: 2,
        expectedEpoch: nextLease.leaseEpoch,
        insertEntries: [live],
        putTips: [{ writerId: WRITER, lastSeq: 3, lastEntryId: live.entryId }],
      })).toBe(3);
    });
    await withRealm(name, (store) => {
      expect(store.restoreBatch(source)).toEqual({ imported: 0, skipped: 2, complete: true });
    });
  });

  it("refuses unmarked existing logs and archive identity conflicts without rebinding", async () => {
    const name = `restore-binding-refuse-${Date.now()}-${Math.random()}`;
    const source = archive();
    await withRealm(name, (store) => store.createLog(LOG));
    await withRealm(name, (store) => expect(() => store.restoreBatch(source)).toThrow(RealmStoreError));
    const pendingName = `restore-binding-pending-conflict-${Date.now()}-${Math.random()}`;
    await withRealm(pendingName, (store) => expect(store.restoreBatch(source, 1).complete).toBe(false));
    const changed = row(source.entries[1]!.entryId, 2, source.entries[0]!.entryId, "six");
    expect(changed.canonicalBytes.byteLength).toBe(source.entries[1]!.canonicalBytes.byteLength);
    const conflict = { ...source, entries: [source.entries[0]!, changed] };
    const pendingBefore = await snapshot(pendingName);
    await withRealm(pendingName, (store) => expect(() => store.restoreBatch(conflict, 1)).toThrow(RealmStoreError));
    expect(await snapshot(pendingName)).toBe(pendingBefore);
    await withRealm(pendingName, (store) => expect(store.restoreBatch(source).complete).toBe(true));
    const completeBefore = await snapshot(pendingName);
    await withRealm(pendingName, (store) => expect(() => store.restoreBatch(conflict)).toThrow(RealmStoreError));
    expect(await snapshot(pendingName)).toBe(completeBefore);
  });

  it("rejects a corrupted pending prefix and a missing completed row", async () => {
    const pendingName = `restore-binding-gap-${Date.now()}-${Math.random()}`;
    const source = archive();
    await withRealm(pendingName, (store) => expect(store.restoreBatch(source, 1).complete).toBe(false));
    await withRealm(pendingName, (_store, state) => {
      state.storage.sql.exec("DROP TRIGGER entries_no_update");
      try {
        state.storage.sql.exec("UPDATE entries SET writer_seq = 2 WHERE log_id = ?", LOG);
      } finally {
        state.storage.sql.exec(`CREATE TRIGGER entries_no_update BEFORE UPDATE ON entries
          BEGIN SELECT RAISE(ABORT, 'entries are immutable'); END`);
      }
    });
    await withRealm(pendingName, (store) => expect(() => store.restoreBatch(source)).toThrow(RealmStoreError));

    const completeName = `restore-binding-missing-${Date.now()}-${Math.random()}`;
    await withRealm(completeName, (store) => expect(store.restoreBatch(source).complete).toBe(true));
    await withRealm(completeName, (_store, state) => {
      state.storage.sql.exec("DROP TRIGGER entries_no_delete");
      try {
        state.storage.sql.exec("DELETE FROM entries WHERE log_id = ? AND writer_seq = 2", LOG);
      } finally {
        state.storage.sql.exec(`CREATE TRIGGER entries_no_delete BEFORE DELETE ON entries
          BEGIN SELECT RAISE(ABORT, 'entries are immutable'); END`);
      }
    });
    await withRealm(completeName, (store) => expect(() => store.restoreBatch(source)).toThrow(RealmStoreError));
  });

  it("keeps ordinary create behavior for an unrelated log", async () => {
    const name = `restore-binding-normal-${Date.now()}-${Math.random()}`;
    const logId = "10000000-0000-4000-8000-000000000105";
    await withRealm(name, (store) => {
      store.createLog(logId);
      expect(store.takeLease(logId).writerId).toMatch(/^[0-9a-f-]{36}$/);
    });
  });
});
