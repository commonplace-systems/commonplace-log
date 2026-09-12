import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { validateEntry } from "../../src/entry";
import { canonicalize } from "../../src/jcs";
import { initSchema } from "../../src/realm/schema";
import {
  RealmStore,
  RealmStoreError,
  type EntryRow,
  type RestoreArchive,
  type RestoreBundle,
} from "../../src/realm/store";

const A_LOG = "30000000-0000-4000-8000-000000000101";
const A_WRITER = "30000000-0000-4000-8000-000000000102";
const B_LOG = "30000000-0000-4000-8000-000000000201";
const B_WRITER = "30000000-0000-4000-8000-000000000202";
const C_LOG = "30000000-0000-4000-8000-000000000301";

function row(
  logId: string,
  writerId: string,
  entryId: string,
  writerSeq: number,
  previous: string | null,
  body: string,
): EntryRow {
  const value = {
    version: 1,
    log_id: logId,
    entry_id: entryId,
    writer_id: writerId,
    writer_seq: writerSeq,
    prev_entry_id: previous,
    created_at: `2026-09-12T00:00:0${writerSeq}Z`,
    body: { bundle: body },
  };
  return {
    entryId,
    writerId,
    writerSeq,
    prevEntryId: previous,
    createdAt: value.created_at,
    canonicalBytes: canonicalize(value),
  };
}

function archive(logId: string, writerId: string, base: string): RestoreArchive {
  const first = row(logId, writerId, entryId(logId, 1), 1, null, `${base}-one`);
  const second = row(logId, writerId, entryId(logId, 2), 2, first.entryId, `${base}-two`);
  const result = { logId, archiveId: `archive-${base}`, writerId, entries: [first, second] };
  for (const entry of result.entries) {
    const checked = validateEntry(entry.canonicalBytes);
    if (!checked.ok || !sameBytes(checked.canonicalBytes, entry.canonicalBytes)) throw new Error(`invalid fixture: ${entry.entryId}`);
  }
  return result;
}

function entryId(logId: string, sequence: number): string {
  return `30000000-0000-4000-8000-0000000${logId.slice(-4)}${sequence}`;
}

function sameBytes(left: Uint8Array, right: Uint8Array): boolean {
  if (left.byteLength !== right.byteLength) return false;
  for (let index = 0; index < left.byteLength; index += 1) {
    if (left[index] !== right[index]) return false;
  }
  return true;
}

function bundle(): RestoreBundle {
  return {
    bundleId: "bundle-30000000",
    logs: [archive(A_LOG, A_WRITER, "a"), archive(B_LOG, B_WRITER, "b")],
  };
}

function largeArchive(index: number): RestoreArchive {
  const suffix = String(400 + index).padStart(4, "0");
  const logId = `30000000-0000-4000-8000-00000000${suffix}`;
  const writerId = `30000000-0000-4000-8000-00000000${String(500 + index).padStart(4, "0")}`;
  const entry = row(logId, writerId, entryId(logId, 1), 1, null, "x".repeat(1_000_000));
  const checked = validateEntry(entry.canonicalBytes);
  if (!checked.ok || !sameBytes(checked.canonicalBytes, entry.canonicalBytes)) throw new Error(`invalid large fixture: ${index}`);
  return { logId, archiveId: `large-${index}`, writerId, entries: [entry] };
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

function provision(sql: SqlStorage): void {
  initSchema(sql);
  sql.exec(
    "INSERT INTO realm_meta (singleton, secret_hash, created_at) VALUES (1, ?, ?)",
    new Uint8Array(32).buffer,
    "2026-09-12T00:00:00Z",
  );
}

function realmMeta(sql: SqlStorage): string {
  return JSON.stringify(sql.exec(
    "SELECT singleton, secret_hash, created_at FROM realm_meta WHERE singleton = 1",
  ).toArray().map((row) => ({
    singleton: Number(row.singleton),
    secretHash: Array.from(new Uint8Array(row.secret_hash as ArrayBuffer)),
    createdAt: String(row.created_at),
  })));
}

function stateSnapshot(sql: SqlStorage): string {
  return JSON.stringify({
    logs: sql.exec("SELECT log_id, revision, lease_epoch, document_writer_id FROM logs ORDER BY log_id").toArray(),
    entries: sql.exec("SELECT log_id, entry_id, writer_id, writer_seq, canonical_json FROM entries ORDER BY log_id, writer_seq").toArray().map((row) => ({
      logId: String(row.log_id),
      entryId: String(row.entry_id),
      writerId: String(row.writer_id),
      writerSeq: Number(row.writer_seq),
      bytes: Array.from(new Uint8Array(row.canonical_json as ArrayBuffer)),
    })),
    tips: sql.exec("SELECT log_id, writer_id, last_seq, last_entry_id FROM writer_tips ORDER BY log_id").toArray(),
    markers: sql.exec("SELECT log_id, archive_id, writer_id, entry_count, total_bytes, manifest_json, state FROM restore_markers ORDER BY log_id").toArray().map((row) => ({
      logId: String(row.log_id), archiveId: String(row.archive_id), writerId: String(row.writer_id),
      entryCount: Number(row.entry_count), totalBytes: Number(row.total_bytes),
      manifest: Array.from(new Uint8Array(row.manifest_json as ArrayBuffer)), state: String(row.state),
    })),
    bundle: sql.exec("SELECT singleton, bundle_id, log_count, digest, state FROM restore_bundles").toArray().map((row) => ({
      singleton: Number(row.singleton), bundleId: String(row.bundle_id), logCount: Number(row.log_count),
      digest: Array.from(new Uint8Array(row.digest as ArrayBuffer)), state: String(row.state),
    })),
    inventory: sql.exec("SELECT bundle_id, log_id, archive_id, writer_id, entry_count, total_bytes, digest, state FROM restore_bundle_logs ORDER BY log_id").toArray().map((row) => ({
      bundleId: String(row.bundle_id), logId: String(row.log_id), archiveId: String(row.archive_id),
      writerId: String(row.writer_id), entryCount: Number(row.entry_count), totalBytes: Number(row.total_bytes),
      digest: Array.from(new Uint8Array(row.digest as ArrayBuffer)), state: String(row.state),
    })),
  });
}

describe("internal restore bundle", () => {
  it("fences every normal API, resumes after restart, replays, and preserves realm_meta", async () => {
    const name = `restore-bundle-${Date.now()}-${Math.random()}`;
    const source = bundle();
    const beforeMeta = await withRealm(name, (_store, sql) => {
      provision(sql);
      return realmMeta(sql);
    });
    expect(await withRealm(name, (store) => store.restoreBundleBatch(source, 1))).toEqual({
      importedLogs: 1,
      skippedLogs: 0,
      complete: false,
    });
    await withRealm(name, (store) => {
      expect(() => store.createLog(C_LOG)).toThrow(RealmStoreError);
      expect(() => store.takeLease(A_LOG)).toThrow(RealmStoreError);
      expect(() => store.readSet(A_LOG, { writers: [], coordinates: [], entryIds: [] })).toThrow(RealmStoreError);
      expect(() => store.commit({ logId: A_LOG, expectedRevision: 0, expectedEpoch: 0, insertEntries: [], putTips: [] }))
        .toThrow(RealmStoreError);
      expect(() => store.frontier(A_LOG)).toThrow(RealmStoreError);
      expect(() => store.readWriter(A_LOG, A_WRITER, { afterSeq: 0, limit: 2 })).toThrow(RealmStoreError);
      expect(() => store.tailLocal(A_LOG, { afterArrival: 0, limit: 2 })).toThrow(RealmStoreError);
      expect(() => store.restoreBatch(source.logs[0]!)).toThrow(RealmStoreError);
    });
    await expect(withRealm(name, async (_store, _sql, state) => {
      await state.storage.sync();
      state.abort("bundle restart");
    })).rejects.toThrow("bundle restart");

    expect(await withRealm(name, (store) => store.restoreBundleBatch(source, 1))).toEqual({
      importedLogs: 1,
      skippedLogs: 1,
      complete: true,
    });
    const restored = await withRealm(name, (store, sql) => ({
      a: store.readWriter(A_LOG, A_WRITER, { afterSeq: 0, throughSeq: 2, limit: 2 }),
      b: store.readWriter(B_LOG, B_WRITER, { afterSeq: 0, throughSeq: 2, limit: 2 }),
      meta: realmMeta(sql),
    }));
    expect(restored.a.entries.map((entry) => entry.writerSeq)).toEqual([1, 2]);
    expect(restored.b.entries.map((entry) => entry.writerSeq)).toEqual([1, 2]);
    expect(sameBytes(restored.a.entries[0]!.canonicalBytes, source.logs[0]!.entries[0]!.canonicalBytes)).toBe(true);
    expect(sameBytes(restored.a.entries[1]!.canonicalBytes, source.logs[0]!.entries[1]!.canonicalBytes)).toBe(true);
    expect(sameBytes(restored.b.entries[0]!.canonicalBytes, source.logs[1]!.entries[0]!.canonicalBytes)).toBe(true);
    expect(sameBytes(restored.b.entries[1]!.canonicalBytes, source.logs[1]!.entries[1]!.canonicalBytes)).toBe(true);
    expect(restored.meta).toBe(beforeMeta);

    const originalTip = source.logs[0]!.entries[1]!.entryId;
    const lease = await withRealm(name, (store) => store.takeLease(A_LOG));
    const followup = row(A_LOG, A_WRITER, "30000000-0000-4000-8000-000000000103", 3, originalTip, "followup");
    expect(await withRealm(name, (store) => store.commit({
      logId: A_LOG,
      expectedRevision: 1,
      expectedEpoch: lease.leaseEpoch,
      insertEntries: [followup],
      putTips: [{ writerId: A_WRITER, lastSeq: 3, lastEntryId: followup.entryId }],
    }))).toBe(2);
    await withRealm(name, (store) => store.createLog(C_LOG));
    expect(await withRealm(name, (store) => store.restoreBundleBatch(source))).toEqual({
      importedLogs: 0,
      skippedLogs: 2,
      complete: true,
    });
    const finalRead = await withRealm(name, (store) => store.readWriter(A_LOG, A_WRITER, { afterSeq: 0, limit: 4 }));
    expect(finalRead.entries.map((entry) => entry.writerSeq)).toEqual([1, 2, 3]);
    expect(sameBytes(finalRead.entries[0]!.canonicalBytes, source.logs[0]!.entries[0]!.canonicalBytes)).toBe(true);
    expect(sameBytes(finalRead.entries[1]!.canonicalBytes, source.logs[0]!.entries[1]!.canonicalBytes)).toBe(true);
    expect(sameBytes(finalRead.entries[2]!.canonicalBytes, followup.canonicalBytes)).toBe(true);
  });

  it("refuses identity, order, preexisting, orphan, and bound violations without mutation", async () => {
    const name = `restore-bundle-refuse-${Date.now()}-${Math.random()}`;
    const source = bundle();
    await withRealm(name, (_store, sql) => provision(sql));
    await withRealm(name, (store) => store.restoreBundleBatch(source, 1));
    const before = await withRealm(name, (_store, sql) => stateSnapshot(sql));
    const wrongId = { ...source, bundleId: "bundle-other" };
    const changed = archive(A_LOG, A_WRITER, "changed");
    const wrongBytes = { ...source, logs: [changed, source.logs[1]!] };
    const wrongOrder = { ...source, logs: [source.logs[1]!, source.logs[0]!] };
    await withRealm(name, (store) => {
      expect(() => store.restoreBundleBatch(wrongId, 1)).toThrow(RealmStoreError);
      expect(() => store.restoreBundleBatch(wrongBytes, 1)).toThrow(RealmStoreError);
      expect(() => store.restoreBundleBatch(wrongOrder, 1)).toThrow(RealmStoreError);
    });
    expect(await withRealm(name, (_store, sql) => stateSnapshot(sql))).toBe(before);

    const preexisting = `restore-bundle-preexisting-${Date.now()}-${Math.random()}`;
    await withRealm(preexisting, (_store, sql) => {
      provision(sql);
      sql.exec("INSERT INTO logs (log_id, format_version, revision, created_at, lease_epoch) VALUES (?, 1, 0, ?, 0)", C_LOG, "now");
    });
    await withRealm(preexisting, (store, sql) => {
      expect(() => store.restoreBundleBatch(source)).toThrow(RealmStoreError);
      expect(sql.exec("SELECT COUNT(*) AS count FROM restore_bundles").one().count).toBe(0);
    });

    const orphan = `restore-bundle-orphan-${Date.now()}-${Math.random()}`;
    await withRealm(orphan, (_store, sql) => {
      provision(sql);
      sql.exec(
        `INSERT INTO restore_bundle_logs (bundle_id, log_id, archive_id, writer_id, entry_count, total_bytes, digest, state)
         VALUES ('orphan', ?, 'archive', ?, 1, 1, ?, 'pending')`,
        A_LOG, A_WRITER, new Uint8Array(32).buffer,
      );
    });
    await withRealm(orphan, (store) => expect(() => store.restoreBundleBatch(source)).toThrow(RealmStoreError));

    const malformed = `restore-bundle-bounds-${Date.now()}-${Math.random()}`;
    await withRealm(malformed, (_store, sql) => provision(sql));
    await withRealm(malformed, (store, sql) => {
      const before = stateSnapshot(sql);
      expect(() => store.restoreBundleBatch({ bundleId: "bounds", logs: new Array(65).fill(source.logs[0]!) })).toThrow(RealmStoreError);
      expect(() => store.restoreBundleBatch(source, 0)).toThrow(RealmStoreError);
      const tooManyEntries = { ...source.logs[0]!, entries: new Array(4097).fill(source.logs[0]!.entries[0]!) };
      expect(() => store.restoreBundleBatch({ bundleId: "too-many-entries", logs: [tooManyEntries, source.logs[1]!] })).toThrow(RealmStoreError);
      const malformedChain = {
        ...source.logs[0]!,
        entries: [source.logs[0]!.entries[0]!, { ...source.logs[0]!.entries[1]!, prevEntryId: null }],
      };
      expect(() => store.restoreBundleBatch({ bundleId: "malformed-chain", logs: [malformedChain, source.logs[1]!] })).toThrow(RealmStoreError);
      const duplicateEntry = {
        ...source.logs[0]!,
        entries: [source.logs[0]!.entries[0]!, { ...source.logs[0]!.entries[1]!, entryId: source.logs[0]!.entries[0]!.entryId }],
      };
      expect(() => store.restoreBundleBatch({ bundleId: "duplicate-entry", logs: [duplicateEntry, source.logs[1]!] })).toThrow(RealmStoreError);
      const multipleWriters = {
        ...source.logs[0]!,
        entries: [{ ...source.logs[0]!.entries[0]!, writerId: B_WRITER }, source.logs[0]!.entries[1]!],
      };
      expect(() => store.restoreBundleBatch({ bundleId: "multiple-writers", logs: [multipleWriters, source.logs[1]!] })).toThrow(RealmStoreError);
      const aggregateOverCap = Array.from({ length: 17 }, (_, index) => largeArchive(index + 1));
      expect(() => store.restoreBundleBatch({ bundleId: "aggregate-over-cap", logs: aggregateOverCap })).toThrow(RealmStoreError);
      const oversized = { ...source.logs[0]!, entries: [{ ...source.logs[0]!.entries[0]!, canonicalBytes: new Uint8Array(16 * 1024 * 1024 + 1) }] };
      expect(() => store.restoreBundleBatch({ bundleId: "oversized", logs: [oversized, source.logs[1]!] })).toThrow(RealmStoreError);
      expect(sql.exec("SELECT COUNT(*) AS count FROM restore_bundles").one().count).toBe(0);
      expect(stateSnapshot(sql)).toBe(before);
    });
  });

  it("rolls back a failed current log while retaining the completed prior batch", async () => {
    const name = `restore-bundle-rollback-${Date.now()}-${Math.random()}`;
    const source = bundle();
    await withRealm(name, (_store, sql) => provision(sql));
    expect((await withRealm(name, (store) => store.restoreBundleBatch(source, 1))).complete).toBe(false);
    const before = await withRealm(name, (_store, sql) => stateSnapshot(sql));
    await withRealm(name, (_store, _sql, state) => {
      state.storage.sql.exec(`CREATE TRIGGER bundle_injected_failure BEFORE INSERT ON entries
        WHEN NEW.log_id = '${B_LOG}' AND NEW.writer_seq = 2
        BEGIN SELECT RAISE(ABORT, 'bundle injected failure'); END`);
    });
    await withRealm(name, (store) => expect(() => store.restoreBundleBatch(source, 1)).toThrow());
    expect(await withRealm(name, (_store, sql) => stateSnapshot(sql))).toBe(before);
    await withRealm(name, (_store, _sql, state) => state.storage.sql.exec("DROP TRIGGER bundle_injected_failure"));
    expect((await withRealm(name, (store) => store.restoreBundleBatch(source, 1))).complete).toBe(true);
  });
});
