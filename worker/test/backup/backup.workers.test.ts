import { env, SELF, listDurableObjectIds, runInDurableObject, createScheduledController } from "cloudflare:test";
import { beforeEach, describe, expect, it } from "vitest";
import { runBackup, type BackupEnv } from "../../backup/run";
import worker from "../../backup/index";
import { RealmStore } from "../../src/realm/store";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    REALMS: DurableObjectNamespace;
    REALM_REGISTRY: KVNamespace;
    BACKUP: R2Bucket;
  }
}

async function request(realm: string, path: string, secret = "", body: unknown = {}, method = "POST") {
  const response = await env.REALMS.get(env.REALMS.idFromName(realm)).fetch(`https://realm.test${path}`, {
    method, headers: {
      authorization: `Bearer ${secret}`, "content-type": "application/json",
      "x-commonplace-realm-id": realm,
      ...(path === "/realm/create" ? { "x-commonplace-realm-create": "1" } : {}),
    }, body: JSON.stringify(body),
  });
  const text = await response.text();
  return { status: response.status, body: text === "" ? null : JSON.parse(text) };
}
async function createRealm() {
  const realm = crypto.randomUUID();
  const created = await request(realm, "/realm/create");
  expect(created.status).toBe(201);
  const row = await env.REALM_REGISTRY.get<{ read_capability: string }>(realm, "json");
  if (row === null) throw new Error("fixture registration absent");
  return { realm, write: String(created.body.realm_secret), read: row.read_capability };
}
async function addLog(realm: string, write: string, log: string) {
  expect((await request(realm, "/create-log", write, { log_id: log })).status).toBe(201);
}
async function append(realm: string, write: string, log: string, writer: string, seq: number, prev: string | null = null) {
  const entry = {
    version: 1, log_id: log, writer_id: writer, writer_seq: seq, entry_id: crypto.randomUUID(),
    prev_entry_id: prev, created_at: "2026-09-05T15:00:00Z", body: { value: `${log}:${seq}` },
  };
  const read = await request(realm, "/read-set", write, { log_id: log, writers: [], coordinates: [], entry_ids: [] });
  expect(read.status).toBe(200);
  const committed = await request(realm, "/commit", write, {
    log_id: log, expected_revision: read.body.read_set.revision, expected_epoch: read.body.read_set.lease_epoch,
    insert_entries: [{ entry_id: entry.entry_id, writer_id: writer, writer_seq: seq, prev_entry_id: prev,
      created_at: entry.created_at, canonical_bytes: btoa(JSON.stringify(entry)) }],
    put_tips: [{ writer_id: writer, last_seq: seq, last_entry_id: entry.entry_id }],
  });
  expect(committed.status).toBe(200);
  return entry;
}
async function listing(prefix = "") {
  const keys: string[] = [];
  let cursor: string | undefined;
  for (;;) {
    const page = await env.BACKUP.list({ prefix, cursor });
    keys.push(...page.objects.map((obj) => obj.key));
    if (!page.truncated) return keys.sort();
    cursor = page.cursor;
  }
}
async function saved(key: string) {
  const item = await env.BACKUP.get(key);
  return item === null ? null : item.json();
}
beforeEach(async () => {
  for (const key of await listing()) await env.BACKUP.delete(key);
  const keys = await env.REALM_REGISTRY.list();
  for (const key of keys.keys) await env.REALM_REGISTRY.delete(key.name);
  expect(await listing()).toEqual([]);
  expect((await env.REALM_REGISTRY.list()).keys).toHaveLength(0);
});

describe("BACKUP-1b-ii", () => {
  it("empty log ID stops backup explicitly and differs from an absent pagination cursor", async () => {
    const { realm, write, read } = await createRealm();
    await addLog(realm, write, "");
    await addLog(realm, write, "log-a");
    await append(realm, write, "", "writer-a", 1);
    const run = await runBackup(env);
    const manifest = await saved(`${realm}/manifest.json`);
    console.info("EMPTY ID", { outcome: run.outcome, manifest });
    expect(run.outcome).toBe("stopped");
    expect(run.realms[0]).toMatchObject({ outcome: "stopped", stop: "unsupported_empty_log_id", manifest_written: false });
    expect(manifest).toBeNull();
    expect(await listing(realm)).toEqual([]);
    expect(await saved(`_runs/${run.run_id}.json`)).toEqual(run);
    const first = await request(realm, "/list-logs", read, { limit: 1 });
    expect(first.body).toEqual({ ok: true, log_ids: [""], next_after_log_id: "" });
    const last = await request(realm, "/list-logs", read, { limit: 1, after_log_id: "" });
    expect(last.body).toEqual({ ok: true, log_ids: ["log-a"], next_after_log_id: null });
    const repeated = await runBackup(env);
    expect(repeated.realms[0]).toMatchObject({ outcome: "stopped", stop: "unsupported_empty_log_id", entries_appended: 0, manifest_written: false });
  });

  it("list-logs requires authority, admits READ alone, pages sorted IDs and stays realm-local", async () => {
    const a = await createRealm(); const b = await createRealm();
    console.info("LIST BASE", (await request(a.realm, "/list-logs", a.read)).body);
    expect(await runInDurableObject(env.REALMS.get(env.REALMS.idFromName(a.realm)), (_i, state) =>
      state.storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name='logs'").toArray())).toEqual([]);
    await addLog(a.realm, a.write, "log-b"); await addLog(a.realm, a.write, "log-a");
    await addLog(b.realm, b.write, "only-b");
    expect((await request(a.realm, "/list-logs")).status).toBe(401);
    expect((await request(a.realm, "/list-logs", b.read)).status).toBe(401);
    const first = await request(a.realm, "/list-logs", a.read, { limit: 1 });
    expect(first).toEqual({ status: 200, body: { ok: true, log_ids: ["log-a"], next_after_log_id: "log-a" } });
    const last = await request(a.realm, "/list-logs", a.read, { limit: 1, after_log_id: "log-a" });
    expect(last.body).toEqual({ ok: true, log_ids: ["log-b"], next_after_log_id: null });
    expect((await request(a.realm, "/list-logs", a.read, { limit: 0 })).status).toBe(400);
    expect((await request(a.realm, "/list-logs", a.read, { limit: 1001 })).status).toBe(400);
    console.info("LIST RESULT no capability=401 other realm=401 READ=200", first.body, last.body);
  });

  it("A1: repeated backup appends zero; identical coordinates across logs remain distinct; new entry adds one", async () => {
    const { realm, write, read } = await createRealm();
    await addLog(realm, write, "log-a"); await addLog(realm, write, "log-b");
    const a = await append(realm, write, "log-a", "writer-a", 1);
    const b = await append(realm, write, "log-b", "writer-a", 1);
    await append(realm, write, "log-a", "writer-b", 1);
    console.info("A1 BASE", await listing(realm));
    const first = await runBackup(env); const firstKeys = await listing(realm);
    expect(first.realms[0]?.entries_appended).toBe(3);
    expect(firstKeys).toHaveLength(6); // three entries, two frontiers, manifest
    expect(await saved(`${realm}/log-a/writer-a/000000000001.json`)).toEqual(a);
    expect(await saved(`${realm}/log-b/writer-a/000000000001.json`)).toEqual(b);
    const second = await runBackup(env); const secondKeys = await listing(realm);
    expect(second.realms[0]).toMatchObject({ entries_appended: 0, frontiers_written: [], manifest_written: false, outcome: "complete" });
    expect(secondKeys).toEqual(firstKeys);
    await append(realm, write, "log-a", "writer-a", 2, a.entry_id);
    const third = await runBackup(env); const thirdKeys = await listing(realm);
    expect(third.realms[0]?.entries_appended).toBe(1);
    expect(thirdKeys).toHaveLength(7);
    console.info("A1 RUN1", firstKeys, "RUN2", secondKeys, "RUN3", thirdKeys);
    // Neither run logs nor entry/frontier/manifest objects contain the stored capability.
    for (const key of await listing()) expect(await (await env.BACKUP.get(key))?.text()).not.toContain(read);
  });

  it("A2: a real checkpoint put failure leaves entries but no frontier/manifest; resume completes", async () => {
    const { realm, write } = await createRealm();
    await addLog(realm, write, "log-a"); await append(realm, write, "log-a", "writer-a", 1);
    console.info("A2 BASE", await listing(realm));
    const storage: BackupEnv["BACKUP"] = {
      get: env.BACKUP.get.bind(env.BACKUP),
      put: async (...args: Parameters<R2Bucket["put"]>) => {
        if (args[0] === `${realm}/log-a/frontier.json`) throw new Error("injected checkpoint failure");
        return env.BACKUP.put(...args);
      },
    };
    const failed = await runBackup({ ...env, BACKUP: storage });
    expect(failed.realms[0]).toMatchObject({ outcome: "stopped", stop: "storage_failed", entries_appended: 1, frontiers_written: [], manifest_written: false });
    const partial = await listing(realm);
    expect(partial).toEqual([`${realm}/log-a/writer-a/000000000001.json`]);
    expect(await saved(`${realm}/log-a/frontier.json`)).toBeNull();
    expect(await saved(`${realm}/manifest.json`)).toBeNull();
    const resumed = await runBackup(env);
    expect(resumed.realms[0]).toMatchObject({ entries_appended: 0, frontiers_written: ["log-a"], manifest_written: true, outcome: "complete" });
    expect(await saved(`${realm}/log-a/frontier.json`)).not.toBeNull();
    console.info("A2 FAILED", partial, "RESUMED", await listing(realm));
  });

  it("A3: second mint is 409; revoke stops only that realm and names the stop in the persisted run log", async () => {
    const a = await createRealm(); const b = await createRealm();
    await addLog(a.realm, a.write, "log-a"); await append(a.realm, a.write, "log-a", "writer-a", 1);
    const first = await runBackup(env);
    expect(first.outcome).toBe("complete");
    console.info("A3 BASE", first.realms.map((r) => ({ realm_id: r.realm_id, outcome: r.outcome })));
    expect(await request(a.realm, "/realm/read-capability", a.write)).toMatchObject({ status: 409, body: { error: { code: "read_capability_exists" } } });
    expect((await request(a.realm, "/realm/read-capability", a.write, {}, "DELETE")).status).toBe(204);
    const stopped = await runBackup(env);
    const log = await saved(`_runs/${stopped.run_id}.json`);
    expect(stopped.outcome).toBe("stopped");
    expect(stopped.realms.find((r) => r.realm_id === a.realm)).toMatchObject({ outcome: "stopped", stop: "capability_rejected", manifest_written: false });
    expect(stopped.realms.find((r) => r.realm_id === b.realm)?.outcome).toBe("complete");
    expect(log).toEqual(stopped);
    console.info("A3 REVOKED", log);
  });

  it("A4: read capability cannot commit even though the write control can", async () => {
    const { realm, write, read } = await createRealm();
    await addLog(realm, write, "log-a");
    const entry = await append(realm, write, "log-a", "writer-a", 1);
    const refused = await request(realm, "/commit", read);
    expect(refused).toMatchObject({ status: 403, body: { error: { code: "forbidden_scope" } } });
    expect((await request(realm, "/frontier", read, { log_id: "log-a" })).body.frontier.writers[0].entry_id).toBe(entry.entry_id);
    console.info("A4 CONTROL write commit=200; READ commit=403 forbidden_scope; frontier unchanged");
  });

  it("A5: existing but unregistered realm is not discovered; run names exact registry coverage", async () => {
    const a = await createRealm(); const b = await createRealm();
    await addLog(a.realm, a.write, "log-a"); await addLog(b.realm, b.write, "log-b");
    const ids = await listDurableObjectIds(env.REALMS);
    let storedRealms = 0;
    for (const id of ids) {
      storedRealms += await runInDurableObject(env.REALMS.get(id), (_instance, state) =>
        Number(state.storage.sql.exec("SELECT count(*) AS n FROM realm_meta").one().n));
    }
    expect(storedRealms).toBe(2);
    expect((await env.REALM_REGISTRY.list()).keys).toHaveLength(2);
    console.info("A5 BASE registry=2 independently read DO realm rows=2");
    await env.REALM_REGISTRY.delete(b.realm);
    const result = await runBackup(env);
    expect(result.registry_count).toBe(1);
    expect(result.coverage).toBe("registered_realms_only");
    expect(result.realms.map((r) => r.realm_id)).toEqual([a.realm]);
    expect(await listing(b.realm)).toEqual([]);
    expect((await request(b.realm, "/frontier", b.read, { log_id: "log-b" })).status).toBe(200);
    console.info("A5 RESULT registry=1 existing DO realms=2 omitted realm still readable=200", result);
  });

  it("test-only HTTP trigger runs; production exports no HTTP trigger and scheduled handler runs", async () => {
    expect("fetch" in worker).toBe(false);
    const response = await SELF.fetch("https://backup.test/run", { method: "POST" });
    expect(response.status).toBe(200);
    expect((await response.json<{ registry_count: number }>()).registry_count).toBe(0);
    await worker.scheduled(createScheduledController(), env);
    expect(await listing("_runs/")).toHaveLength(2);
  });

  it("conflicting immutable entry bytes stop the log without overwriting or advancing its frontier", async () => {
    const { realm, write } = await createRealm();
    await addLog(realm, write, "log-a"); await append(realm, write, "log-a", "writer-a", 1);
    const key = `${realm}/log-a/writer-a/000000000001.json`;
    await env.BACKUP.put(key, "conflicting bytes");
    const result = await runBackup(env);
    expect(result.realms[0]).toMatchObject({ outcome: "stopped", stop: "backup_entry_conflict" });
    expect(await (await env.BACKUP.get(key))?.text()).toBe("conflicting bytes");
    expect(await saved(`${realm}/log-a/frontier.json`)).toBeNull();
  });

  it("paginates the registry, log inventory, and writer sequence without skipping entries", async () => {
    const a = await createRealm(); const b = await createRealm();
    await runInDurableObject(env.REALMS.get(env.REALMS.idFromName(a.realm)), (_i, state) => {
      const store = new RealmStore(state.storage.sql, state.storage);
      for (let n = 0; n < 101; n++) store.createLog(`log-${String(n).padStart(3, "0")}`);
      let previous: string | null = null;
      for (let n = 1; n <= 101; n++) {
        const entryId: string = crypto.randomUUID();
        const entry = { version: 1, log_id: "log-100", writer_id: "writer-a", writer_seq: n,
          entry_id: entryId, prev_entry_id: previous, created_at: "2026-09-05T15:00:00Z", body: { n } };
        store.commit({ logId: entry.log_id, expectedRevision: n - 1, expectedEpoch: 0,
          insertEntries: [{ entryId: entry.entry_id, writerId: entry.writer_id, writerSeq: n,
            prevEntryId: previous, createdAt: entry.created_at, canonicalBytes: new TextEncoder().encode(JSON.stringify(entry)) }],
          putTips: [{ writerId: entry.writer_id, lastSeq: n, lastEntryId: entry.entry_id }] });
        previous = entryId;
      }
    });
    const registry: BackupEnv["REALM_REGISTRY"] = {
      get: env.REALM_REGISTRY.get.bind(env.REALM_REGISTRY),
      list: (opts) => env.REALM_REGISTRY.list({ ...opts, limit: 1 }),
    };
    const result = await runBackup({ ...env, REALM_REGISTRY: registry });
    expect(result.outcome).toBe("complete");
    expect(result.registry_count).toBe(2);
    expect(result.realms.find((r) => r.realm_id === a.realm)?.entries_appended).toBe(101);
    expect(result.realms.find((r) => r.realm_id === a.realm)?.frontiers_written).toHaveLength(101);
    expect(result.realms.find((r) => r.realm_id === b.realm)?.outcome).toBe("complete");
    const last = await saved(`${a.realm}/log-100/writer-a/000000000101.json`);
    expect(last).toMatchObject({ writer_seq: 101, body: { n: 101 } });
    console.info("PAGING registry pages=2 log pages=2 writer pages=2 entries=101 frontiers=101");
  });
});
