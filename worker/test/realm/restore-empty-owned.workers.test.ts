import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { validateEntry } from "../../src/entry";
import { canonicalize } from "../../src/jcs";
import { initSchema } from "../../src/realm/schema";
import { REALM_CREATE_HEADER, REALM_ID_HEADER } from "../../src/realm/realm_auth";
import {
  RealmStore,
  RealmStoreError,
  type EntryRow,
  type RestoreArchive,
  type RestoreBundle,
} from "../../src/realm/store";

const EMPTY_LOG = "60000000-0000-4000-8000-000000000101";
const EMPTY_WRITER = "60000000-0000-4000-8000-000000000102";
const NONEMPTY_LOG = "60000000-0000-4000-8000-000000000201";
const NONEMPTY_WRITER = "60000000-0000-4000-8000-000000000202";
const NONEMPTY_ENTRY = "60000000-0000-4000-8000-000000000203";
const ALT_WRITER = "60000000-0000-4000-8000-000000000302";

type Json = Record<string, any>;
type StorageInstance = { storageFetch(request: Request): Promise<Response> };

function row(
  logId: string,
  writerId: string,
  entryId: string,
  writerSeq: number,
  prevEntryId: string | null,
  body: string,
): EntryRow {
  const value = {
    version: 1,
    log_id: logId,
    entry_id: entryId,
    writer_id: writerId,
    writer_seq: writerSeq,
    prev_entry_id: prevEntryId,
    created_at: `2026-09-13T00:00:0${writerSeq}Z`,
    body: { empty_owned: body },
  };
  const canonicalBytes = canonicalize(value);
  const checked = validateEntry(canonicalBytes);
  if (!checked.ok || !sameBytes(checked.canonicalBytes, canonicalBytes)) {
    throw new Error(`invalid empty-owned fixture entry: ${entryId}`);
  }
  return { entryId, writerId, writerSeq, prevEntryId, createdAt: value.created_at, canonicalBytes };
}

function emptyArchive(
  logId = EMPTY_LOG,
  writerId = EMPTY_WRITER,
  archiveId = "empty-owned-archive",
): RestoreArchive {
  return { logId, archiveId, writerId, entries: [] };
}

function nonemptyArchive(): RestoreArchive {
  return {
    logId: NONEMPTY_LOG,
    archiveId: "empty-owned-nonempty-archive",
    writerId: NONEMPTY_WRITER,
    entries: [row(NONEMPTY_LOG, NONEMPTY_WRITER, NONEMPTY_ENTRY, 1, null, "one")],
  };
}

function bundle(bundleId: string, logs: RestoreArchive[]): RestoreBundle {
  return { bundleId, logs };
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false;
  for (let index = 0; index < left.byteLength; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

async function withRealm<T>(
  name: string,
  fn: (store: RealmStore, sql: SqlStorage, state: DurableObjectState) => T | Promise<T>,
): Promise<T> {
  const stub = realmStub(name);
  return await runInDurableObject(stub, (_instance, state) =>
    fn(new RealmStore(state.storage.sql, state.storage), state.storage.sql, state),
  );
}

function realmStub(name: string): DurableObjectStub {
  return env.REALM_CONTAINER.get(env.REALM_CONTAINER.idFromName(`restore-empty-owned-${name}`));
}

async function createRealm(target: DurableObjectStub): Promise<string> {
  const response = await target.fetch("https://realm.invalid/realm/create", {
    method: "POST",
    headers: { [REALM_CREATE_HEADER]: "1", [REALM_ID_HEADER]: crypto.randomUUID() },
    body: "{}",
  });
  expect(response.status).toBe(201);
  return (await response.json() as Json).realm_secret;
}

async function internal(
  target: DurableObjectStub,
  path: string,
  body: unknown,
): Promise<{ status: number; json: Json }> {
  return await runInDurableObject(target, async (instance) => {
    const response = await (instance as unknown as StorageInstance).storageFetch(new Request(
      `https://storage.internal${path}`,
      { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body) },
    ));
    return { status: response.status, json: await response.json() as Json };
  });
}

function provision(sql: SqlStorage): void {
  initSchema(sql);
  sql.exec(
    "INSERT INTO realm_meta (singleton, secret_hash, created_at) VALUES (1, ?, ?)",
    new Uint8Array(32).buffer,
    "2026-09-13T00:00:00Z",
  );
}

function snapshot(sql: SqlStorage): string {
  return JSON.stringify({
    logs: sql.exec("SELECT log_id, revision, lease_epoch, document_writer_id FROM logs ORDER BY log_id").toArray(),
    entries: sql.exec("SELECT log_id, entry_id, writer_id, writer_seq, canonical_json FROM entries ORDER BY log_id, writer_seq").toArray().map((value) => ({
      logId: String(value.log_id),
      entryId: String(value.entry_id),
      writerId: String(value.writer_id),
      writerSeq: Number(value.writer_seq),
      bytes: Array.from(new Uint8Array(value.canonical_json as ArrayBuffer)),
    })),
    tips: sql.exec("SELECT log_id, writer_id, last_seq, last_entry_id FROM writer_tips ORDER BY log_id").toArray(),
    markers: sql.exec("SELECT log_id, archive_id, writer_id, entry_count, total_bytes, state FROM restore_markers ORDER BY log_id").toArray(),
    bundle: sql.exec("SELECT singleton, bundle_id, log_count, state FROM restore_bundles").toArray(),
    bundleLogs: sql.exec("SELECT bundle_id, log_id, archive_id, writer_id, entry_count, total_bytes, digest, state FROM restore_bundle_logs ORDER BY log_id").toArray(),
  });
}

describe("internal restore of configured empty owned logs", () => {
  it("creates a complete catalog marker for a configured non-null writer with no entries", async () => {
    const name = `empty-catalog-${Date.now()}-${Math.random()}`;
    const target = realmStub(name);
    const secret = await createRealm(target);
    const unauthenticated = await target.fetch("https://realm.invalid/restore-bundle-batch", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({}),
    });
    expect(unauthenticated.status).toBe(401);
    expect(await unauthenticated.json()).toEqual({ ok: false, error: { code: "unauthorized" } });

    const authenticated = await target.fetch("https://realm.invalid/restore-bundle-batch", {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${secret}` },
      body: JSON.stringify({}),
    });
    expect(authenticated.status).toBe(404);
    expect(await authenticated.json()).toEqual({ ok: false, error: { code: "not_found" } });

    const restore = await internal(target, "/restore-bundle-batch", {
      bundle_id: "empty-owned-bundle",
      max_logs: 1,
      logs: [{ log_id: EMPTY_LOG, archive_id: "empty-owned-archive", writer_id: EMPTY_WRITER, entries: [] }],
    });
    expect(restore).toEqual({
      status: 200,
      json: { ok: true, result: { imported_logs: 1, skipped_logs: 0, complete: true } },
    });
    const result = await withRealm(name, (_store, sql) => {
      const log = sql.exec("SELECT revision, lease_epoch, document_writer_id FROM logs WHERE log_id = ?", EMPTY_LOG).one();
      const marker = sql.exec("SELECT entry_count, total_bytes, state FROM restore_markers WHERE log_id = ?", EMPTY_LOG).one();
      return {
        log: {
          revision: Number(log.revision),
          leaseEpoch: Number(log.lease_epoch),
          documentWriterId: String(log.document_writer_id),
        },
        entries: Number(sql.exec("SELECT COUNT(*) AS count FROM entries WHERE log_id = ?", EMPTY_LOG).one().count),
        tips: Number(sql.exec("SELECT COUNT(*) AS count FROM writer_tips WHERE log_id = ?", EMPTY_LOG).one().count),
        marker: {
          entryCount: Number(marker.entry_count),
          totalBytes: Number(marker.total_bytes),
          state: String(marker.state),
        },
      };
    });

    expect(result.log.revision).toBe(0);
    expect(result.log.leaseEpoch).toBe(0);
    expect(result.log.documentWriterId).toBe(EMPTY_WRITER);
    expect(result.entries).toBe(0);
    expect(result.tips).toBe(0);
    expect(result.marker.entryCount).toBe(0);
    expect(result.marker.totalBytes).toBe(0);
    expect(result.marker.state).toBe("complete");
  });

  it("fences normal APIs during a mixed empty and non-empty pending bundle, then completes", async () => {
    const name = `empty-mixed-${Date.now()}-${Math.random()}`;
    const source = bundle("empty-owned-mixed", [emptyArchive(), nonemptyArchive()]);

    expect(await withRealm(name, (store, sql) => {
      provision(sql);
      return store.restoreBundleBatch(source, 1);
    })).toEqual({ importedLogs: 1, skippedLogs: 0, complete: false });

    await withRealm(name, (store) => {
      expect(() => store.createLog("60000000-0000-4000-8000-000000000401")).toThrow(RealmStoreError);
      expect(() => store.takeLease(EMPTY_LOG)).toThrow(RealmStoreError);
      expect(() => store.frontier(EMPTY_LOG)).toThrow(RealmStoreError);
    });

    const completed = await withRealm(name, (store) => ({
      result: store.restoreBundleBatch(source, 1),
      empty: store.frontier(EMPTY_LOG),
      nonempty: store.readWriter(NONEMPTY_LOG, NONEMPTY_WRITER, { afterSeq: 0, throughSeq: 1, limit: 1 }),
    }));

    expect(completed.result).toEqual({ importedLogs: 1, skippedLogs: 1, complete: true });
    expect(completed.empty).toEqual({ writers: [] });
    expect(completed.nonempty.entries.map((entry) => entry.writerSeq)).toEqual([1]);
  });

  it("replays an empty owned bundle idempotently without changing SQLite state", async () => {
    const name = `empty-replay-${Date.now()}-${Math.random()}`;
    const source = bundle("empty-owned-replay", [emptyArchive()]);
    await withRealm(name, (store, sql) => {
      provision(sql);
      expect(store.restoreBundleBatch(source)).toEqual({ importedLogs: 1, skippedLogs: 0, complete: true });
      return snapshot(sql);
    });

    const before = await withRealm(name, (_store, sql) => snapshot(sql));
    const replay = await withRealm(name, (store) => store.restoreBundleBatch(source));
    const after = await withRealm(name, (_store, sql) => snapshot(sql));

    expect(replay).toEqual({ importedLogs: 0, skippedLogs: 1, complete: true });
    expect(after).toBe(before);
  });

  it("takes a lease and commits after empty restore, then replay preserves the tip and lease", async () => {
    const name = `empty-append-${Date.now()}-${Math.random()}`;
    const source = bundle("empty-owned-append", [emptyArchive()]);
    const followup = row(EMPTY_LOG, EMPTY_WRITER, "60000000-0000-4000-8000-000000000103", 1, null, "followup");

    const beforeReplay = await withRealm(name, (store, sql) => {
      provision(sql);
      expect(store.restoreBundleBatch(source)).toEqual({ importedLogs: 1, skippedLogs: 0, complete: true });
      const lease = store.takeLease(EMPTY_LOG);
      expect(lease.writerId).toBe(EMPTY_WRITER);
      expect(store.commit({
        logId: EMPTY_LOG,
        expectedRevision: 0,
        expectedEpoch: lease.leaseEpoch,
        insertEntries: [followup],
        putTips: [{ writerId: EMPTY_WRITER, lastSeq: 1, lastEntryId: followup.entryId }],
      })).toBe(1);
      return snapshot(sql);
    });

    const replay = await withRealm(name, (store) => store.restoreBundleBatch(source));
    const afterReplay = await withRealm(name, (store, sql) => ({
      state: snapshot(sql),
      frontier: store.frontier(EMPTY_LOG),
      entries: store.readWriter(EMPTY_LOG, EMPTY_WRITER, { afterSeq: 0, throughSeq: 1, limit: 1 }),
    }));

    expect(replay).toEqual({ importedLogs: 0, skippedLogs: 1, complete: true });
    expect(afterReplay.state).toBe(beforeReplay);
    expect(afterReplay.frontier).toEqual({ writers: [{ writerId: EMPTY_WRITER, seq: 1, entryId: followup.entryId }] });
    expect(afterReplay.entries.entries.map((entry) => entry.writerSeq)).toEqual([1]);
  });

  it("refuses an existing unmarked empty target and writer, archive, or bundle rebinding", async () => {
    const targetName = `empty-existing-${Date.now()}-${Math.random()}`;
    const source = emptyArchive();
    await withRealm(targetName, (store, sql) => {
      provision(sql);
      store.createLog(EMPTY_LOG, { formatVersion: 1, createdAt: "2026-09-13T00:00:00Z" });
      expect(() => store.restoreBundleBatch(bundle("empty-owned-existing", [source]))).toThrow(RealmStoreError);
      expect(Number(sql.exec("SELECT COUNT(*) AS count FROM logs").one().count)).toBe(1);
      expect(Number(sql.exec("SELECT COUNT(*) AS count FROM entries").one().count)).toBe(0);
      expect(Number(sql.exec("SELECT COUNT(*) AS count FROM restore_bundles").one().count)).toBe(0);
      expect(Number(sql.exec("SELECT COUNT(*) AS count FROM restore_bundle_logs").one().count)).toBe(0);
    });

    const rebindName = `empty-rebind-${Date.now()}-${Math.random()}`;
    await withRealm(rebindName, (store, sql) => {
      provision(sql);
      expect(store.restoreBundleBatch(bundle("empty-owned-rebind", [source]))).toEqual({ importedLogs: 1, skippedLogs: 0, complete: true });
      expect(() => store.restoreBundleBatch(bundle("empty-owned-rebind", [emptyArchive(EMPTY_LOG, ALT_WRITER, source.archiveId)]))).toThrow(RealmStoreError);
      expect(() => store.restoreBundleBatch(bundle("empty-owned-other", [emptyArchive(EMPTY_LOG, EMPTY_WRITER, "other-archive")]))).toThrow(RealmStoreError);
    });
  });

  it("fails closed for zero-byte entries and inconsistent restore count metadata", async () => {
    const nullWriterName = `empty-null-writer-${Date.now()}-${Math.random()}`;
    const nullWriterTarget = realmStub(nullWriterName);
    await createRealm(nullWriterTarget);
    expect(await internal(nullWriterTarget, "/restore-bundle-batch", {
      bundle_id: "empty-owned-null-writer",
      max_logs: 1,
      logs: [{ log_id: EMPTY_LOG, archive_id: "empty-owned-null-writer", writer_id: null, entries: [] }],
    })).toEqual({ status: 400, json: { ok: false, error: { code: "malformed" } } });
    const nullWriterState = await withRealm(nullWriterName, (_store, sql) => {
      initSchema(sql);
      return {
        logs: Number(sql.exec("SELECT COUNT(*) AS count FROM logs").one().count),
        entries: Number(sql.exec("SELECT COUNT(*) AS count FROM entries").one().count),
      };
    });
    expect(nullWriterState).toEqual({ logs: 0, entries: 0 });

    const malformedName = `empty-malformed-${Date.now()}-${Math.random()}`;
    const malformed: RestoreArchive = {
      logId: EMPTY_LOG,
      archiveId: "empty-owned-zero-byte",
      writerId: EMPTY_WRITER,
      entries: [{
        entryId: "60000000-0000-4000-8000-000000000104",
        writerId: EMPTY_WRITER,
        writerSeq: 1,
        prevEntryId: null,
        createdAt: "2026-09-13T00:00:01Z",
        canonicalBytes: new Uint8Array(0),
      }],
    };
    await withRealm(malformedName, (store, sql) => {
      provision(sql);
      expect(() => store.restoreBundleBatch(bundle("empty-owned-zero-byte", [malformed]))).toThrow(RealmStoreError);
      expect(Number(sql.exec("SELECT COUNT(*) AS count FROM logs").one().count)).toBe(0);
    });

    const countName = `empty-count-metadata-${Date.now()}-${Math.random()}`;
    const source = bundle("empty-owned-count", [emptyArchive()]);
    await withRealm(countName, (store, sql) => {
      provision(sql);
      expect(store.restoreBundleBatch(source)).toEqual({ importedLogs: 1, skippedLogs: 0, complete: true });
      sql.exec("UPDATE restore_markers SET entry_count = 1 WHERE log_id = ?", EMPTY_LOG);
      expect(() => store.restoreBundleBatch(source)).toThrow(RealmStoreError);
      sql.exec("UPDATE restore_markers SET entry_count = 0 WHERE log_id = ?", EMPTY_LOG);
      sql.exec("UPDATE restore_bundle_logs SET total_bytes = 1 WHERE log_id = ?", EMPTY_LOG);
      expect(() => store.frontier(EMPTY_LOG)).toThrow(RealmStoreError);
    });
  });
});
