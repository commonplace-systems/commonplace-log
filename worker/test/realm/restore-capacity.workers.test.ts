import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { canonicalize } from "../../src/jcs";
import { RealmStore, type EntryRow, type RestoreArchive } from "../../src/realm/store";

const LOG = "20000000-0000-4000-8000-000000000101";
const WRITER = "20000000-0000-4000-8000-000000000102";
const ENTRY = "20000000-0000-4000-8000-000000000103";
const FOLLOWUP = "20000000-0000-4000-8000-000000000104";
const BODY_LENGTH = 900_000;

function largeEntry(): EntryRow {
  const value = {
    version: 1,
    log_id: LOG,
    entry_id: ENTRY,
    writer_id: WRITER,
    writer_seq: 1,
    prev_entry_id: null,
    created_at: "2026-09-12T00:00:00Z",
    body: { capacity_payload: "x".repeat(BODY_LENGTH) },
  };

  return {
    entryId: ENTRY,
    writerId: WRITER,
    writerSeq: 1,
    prevEntryId: null,
    createdAt: value.created_at,
    canonicalBytes: canonicalize(value),
  };
}

function archive(entry: EntryRow): RestoreArchive {
  return {
    logId: LOG,
    archiveId: "capacity-archive-20000000",
    writerId: WRITER,
    entries: [entry],
  };
}

async function withRealm<T>(name: string, fn: (store: RealmStore, sql: SqlStorage) => T | Promise<T>): Promise<T> {
  const stub = env.REALM_CONTAINER.get(env.REALM_CONTAINER.idFromName(name));
  return await runInDurableObject(stub, (_instance, state) => fn(
    new RealmStore(state.storage.sql, state.storage),
    state.storage.sql,
  ));
}

describe("restore capacity boundary", () => {
  it("restores a near-900KiB canonical entry and preserves bytes after lease append/reopen", async () => {
    const name = `restore-capacity-${Date.now()}-${Math.random()}`;
    const entry = largeEntry();
    const source = archive(entry);

    expect(BODY_LENGTH).toBe(900_000);
    expect(entry.canonicalBytes.byteLength).toBeGreaterThan(850_000);
    expect(entry.canonicalBytes.byteLength).toBeLessThan(1_048_576);

    const restored = await withRealm(name, (store, sql) => {
      const result = store.restoreBatch(source);
      const marker = sql.exec(
        "SELECT total_bytes, length(manifest_json) AS manifest_bytes FROM restore_markers WHERE log_id = ?",
        LOG,
      ).one();
      return {
        result,
        totalBytes: Number(marker.total_bytes),
        manifestBytes: Number(marker.manifest_bytes),
      };
    });

    expect(restored.result).toEqual({ imported: 1, skipped: 0, complete: true });
    expect(restored.totalBytes).toBe(entry.canonicalBytes.byteLength);
    expect(restored.manifestBytes).toBeGreaterThan(entry.canonicalBytes.byteLength * 3);

    const lease = await withRealm(name, (store) => store.takeLease(LOG));
    expect(lease.writerId).toBe(WRITER);
    const followup: EntryRow = {
      entryId: FOLLOWUP,
      writerId: WRITER,
      writerSeq: 2,
      prevEntryId: ENTRY,
      createdAt: "2026-09-12T00:00:01Z",
      canonicalBytes: canonicalize({
        version: 1,
        log_id: LOG,
        entry_id: FOLLOWUP,
        writer_id: WRITER,
        writer_seq: 2,
        prev_entry_id: ENTRY,
        created_at: "2026-09-12T00:00:01Z",
        body: { capacity_followup: true },
      }),
    };

    expect(await withRealm(name, (store) => store.commit({
      logId: LOG,
      expectedRevision: 1,
      expectedEpoch: lease.leaseEpoch,
      insertEntries: [followup],
      putTips: [{ writerId: WRITER, lastSeq: 2, lastEntryId: FOLLOWUP }],
    }))).toBe(2);

    const reopened = await withRealm(name, (store) => store.readWriter(LOG, WRITER, {
      afterSeq: 0,
      throughSeq: 2,
      limit: 2,
    }));
    expect(reopened.entries.map((item) => item.writerSeq)).toEqual([1, 2]);
    expect(reopened.entries[0]?.canonicalBytes).toEqual(entry.canonicalBytes);
    expect(reopened.entries[1]?.canonicalBytes).toEqual(followup.canonicalBytes);
  });
});
