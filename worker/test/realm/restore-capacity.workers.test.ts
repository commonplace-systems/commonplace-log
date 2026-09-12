import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { validateEntry } from "../../src/entry";
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

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false;
  for (let index = 0; index < left.byteLength; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

function progress(phase: string, fields: Record<string, number | boolean> = {}): void {
  console.info(JSON.stringify({ restore_capacity_phase: phase, ...fields }));
}

async function withRealm<T>(
  name: string,
  fn: (store: RealmStore, sql: SqlStorage, state: DurableObjectState) => T | Promise<T>,
): Promise<T> {
  const stub = env.REALM_CONTAINER.get(env.REALM_CONTAINER.idFromName(name));
  return await runInDurableObject(stub, (_instance, state) => fn(
    new RealmStore(state.storage.sql, state.storage),
    state.storage.sql,
    state,
  ));
}

describe("restore capacity boundary", () => {
  it("restores a near-900KiB canonical entry and preserves bytes after lease append/reopen", async () => {
    const name = `restore-capacity-${Date.now()}-${Math.random()}`;
    const entry = largeEntry();
    const source = archive(entry);
    progress("fixture_built", { entry_count: source.entries.length });

    expect(BODY_LENGTH).toBe(900_000);
    expect(entry.canonicalBytes.byteLength).toBeGreaterThan(850_000);
    expect(entry.canonicalBytes.byteLength).toBeLessThan(1_048_576);
    const validation = validateEntry(entry.canonicalBytes);
    if (!validation.ok) throw new Error(`capacity fixture entry rejected: ${validation.reason}`);
    expect(sameBytes(validation.canonicalBytes, entry.canonicalBytes)).toBe(true);
    progress("entry_validated", { validated_count: 1 });
    console.info(JSON.stringify({
      restore_capacity_body_bytes: BODY_LENGTH,
      restore_capacity_canonical_bytes: entry.canonicalBytes.byteLength,
    }));

    progress("restore_started", { entry_count: source.entries.length });
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
    expect(restored.manifestBytes).toBeGreaterThan(0);
    expect(restored.manifestBytes).toBeLessThan(128);
    progress("restore_marker_stored", { imported_count: restored.result.imported, marker_bytes: restored.manifestBytes });
    console.info(JSON.stringify({
      restore_capacity_total_bytes: restored.totalBytes,
      restore_capacity_manifest_bytes: restored.manifestBytes,
    }));

    const lease = await withRealm(name, (store) => store.takeLease(LOG));
    expect(lease.writerId).toBe(WRITER);
    progress("lease_acquired", { lease_epoch: lease.leaseEpoch });
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
    progress("followup_committed", { committed_count: 1 });

    await expect(withRealm(name, async (_store, _sql, state) => {
      await state.storage.sync();
      state.abort("restore capacity restart");
    })).rejects.toThrow("restore capacity restart");
    progress("restart_completed", { reopened: true });

    const reopened = await withRealm(name, (store) => store.readWriter(LOG, WRITER, {
      afterSeq: 0,
      throughSeq: 2,
      limit: 2,
    }));
    expect(reopened.entries.map((item) => item.writerSeq)).toEqual([1, 2]);
    expect(reopened.entries[0] === undefined ? false : sameBytes(reopened.entries[0].canonicalBytes, entry.canonicalBytes)).toBe(true);
    expect(reopened.entries[1] === undefined ? false : sameBytes(reopened.entries[1].canonicalBytes, followup.canonicalBytes)).toBe(true);
    progress("readback_verified", { read_count: reopened.entries.length });
  }, 20_000);
});
