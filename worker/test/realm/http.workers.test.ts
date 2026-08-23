import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { handleRealmRequest } from "../../src/realm/http";
import { RealmStore, RealmStoreError } from "../../src/realm/store";

let realmSequence = 0;

type JsonObject = Record<string, any>;

function realmStub() {
  const namespace = env.REALM_CONTAINER;
  const name = `realm-http-${Date.now()}-${realmSequence++}`;
  return namespace.get(namespace.idFromName(name));
}

async function post(stub: DurableObjectStub, path: string, body: unknown): Promise<{
  status: number;
  json: JsonObject;
}> {
  const response = await stub.fetch(`https://realm.invalid${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  });
  return { status: response.status, json: await response.json() as JsonObject };
}

function canonical(fields: {
  entry_id: string;
  writer_id: string;
  writer_seq: number;
  prev_entry_id: string | null;
  created_at: string;
}): string {
  return btoa(JSON.stringify(fields));
}

function entry(
  entryId: string,
  writerId: string,
  writerSeq: number,
  prevEntryId: string | null,
  createdAt = "2026-08-23T12:34:56Z",
) {
  return {
    entry_id: entryId,
    writer_id: writerId,
    writer_seq: writerSeq,
    prev_entry_id: prevEntryId,
    created_at: createdAt,
    canonical_bytes: canonical({
      entry_id: entryId,
      writer_id: writerId,
      writer_seq: writerSeq,
      prev_entry_id: prevEntryId,
      created_at: createdAt,
    }),
  };
}

function plan(logId: string, revision: number, epoch: number, entries: ReturnType<typeof entry>[]) {
  const lastByWriter = new Map<string, ReturnType<typeof entry>>();
  for (const item of entries) lastByWriter.set(item.writer_id, item);
  return {
    log_id: logId,
    expected_revision: revision,
    expected_epoch: epoch,
    insert_entries: entries,
    put_tips: [...lastByWriter.values()].map((item) => ({
      writer_id: item.writer_id,
      last_seq: item.writer_seq,
      last_entry_id: item.entry_id,
    })),
  };
}

async function createLog(stub: DurableObjectStub, logId: string): Promise<void> {
  expect(await post(stub, "/create-log", {
    log_id: logId,
    format_version: 1,
    created_at: "2026-08-23T00:00:00Z",
  })).toEqual({ status: 201, json: { ok: true } });
}

async function inspect(stub: DurableObjectStub): Promise<JsonObject> {
  return await runInDurableObject(stub, (_instance, state) => ({
    catalog: state.storage.sql
      .exec("SELECT name, type, sql FROM sqlite_master ORDER BY name")
      .toArray(),
    logs: state.storage.sql.exec("SELECT * FROM logs ORDER BY log_id").toArray(),
    entries: state.storage.sql
      .exec(`SELECT log_id, entry_id, writer_id, writer_seq, prev_entry_id, created_at,
                    canonical_json, received_at_ms FROM entries ORDER BY arrival_seq`)
      .toArray()
      .map((row) => ({ ...row, canonical_json: new TextDecoder().decode(row.canonical_json as ArrayBuffer) })),
    tips: state.storage.sql.exec("SELECT * FROM writer_tips ORDER BY log_id, writer_id").toArray(),
  }));
}

async function logicalCommit(
  stub: DurableObjectStub,
  logId: string,
  incoming: ReturnType<typeof entry>[],
): Promise<{ requests: string[]; result: JsonObject }> {
  const requests: string[] = [];
  const request = async (path: string, body: unknown) => {
    requests.push(path);
    return await post(stub, path, body);
  };
  const read = await request("/read-set", {
    log_id: logId,
    writers: [...new Set(incoming.map((item) => item.writer_id))],
    coordinates: incoming.map((item) => ({ writer_id: item.writer_id, writer_seq: item.writer_seq })),
    entry_ids: incoming.map((item) => item.entry_id),
  });
  expect(read.status).toBe(200);
  const result = await request(
    "/commit",
    plan(logId, read.json.read_set.revision, read.json.read_set.lease_epoch, incoming),
  );
  return { requests, result };
}

describe("RealmContainer HTTP contract", () => {
  it("advances leases and fences an earlier lease without writing rows", async () => {
    const stub = realmStub();
    await createLog(stub, "lease-log");
    expect(await post(stub, "/take-lease", { log_id: "lease-log" }))
      .toEqual({ status: 200, json: { ok: true, lease_epoch: 1 } });
    expect(await post(stub, "/take-lease", { log_id: "lease-log" }))
      .toEqual({ status: 200, json: { ok: true, lease_epoch: 2 } });

    const before = await inspect(stub);
    const obsolete = await post(stub, "/commit", plan("lease-log", 0, 1, [entry("old", "alice", 1, null)]));
    expect(obsolete).toEqual({ status: 409, json: { ok: false, error: { code: "obsolete_epoch" } } });
    const after = await inspect(stub);
    expect(after.entries).toEqual(before.entries);
    expect(after.tips).toEqual(before.tips);
    expect(after.logs).toEqual(before.logs);
  });

  it("does not create schema or rows when taking a lease for an unknown log", async () => {
    const stub = realmStub();
    const before = await runInDurableObject(stub, (_instance, state) => ({
      catalog: state.storage.sql.exec("SELECT name, type, sql FROM sqlite_master ORDER BY name").toArray(),
      counts: state.storage.sql.exec("SELECT total_changes() AS n").one().n,
    }));
    expect(await post(stub, "/take-lease", { log_id: "missing" }))
      .toEqual({ status: 404, json: { ok: false, error: { code: "not_found" } } });
    const after = await runInDurableObject(stub, (_instance, state) => ({
      catalog: state.storage.sql.exec("SELECT name, type, sql FROM sqlite_master ORDER BY name").toArray(),
      counts: state.storage.sql.exec("SELECT total_changes() AS n").one().n,
    }));
    expect(after).toEqual(before);

    const initialized = realmStub();
    await createLog(initialized, "known");
    const initializedBefore = await inspect(initialized);
    expect(await post(initialized, "/take-lease", { log_id: "still-missing" }))
      .toEqual({ status: 404, json: { ok: false, error: { code: "not_found" } } });
    expect(await inspect(initialized)).toEqual(initializedBefore);
  });

  it("assigns local receipt times and rejects caller-supplied receipt metadata", async () => {
    const stub = realmStub();
    await createLog(stub, "receipt-log");
    expect(await post(stub, "/commit", plan("receipt-log", 0, 0, [entry("one", "alice", 1, null)])))
      .toEqual({ status: 200, json: { ok: true, revision: 1 } });
    await new Promise((resolve) => setTimeout(resolve, 2));
    expect(await post(stub, "/commit", plan("receipt-log", 1, 0, [entry("two", "bob", 1, null)])))
      .toEqual({ status: 200, json: { ok: true, revision: 2 } });
    const afterSecond = Date.now();
    const stored = (await inspect(stub)).entries;
    expect(stored[0].received_at_ms).toBeGreaterThan(0);
    expect(stored[1].received_at_ms).toBeGreaterThan(stored[0].received_at_ms);
    expect(stored[1].received_at_ms).toBeLessThanOrEqual(afterSecond);

    const beforeRejected = await inspect(stub);
    const supplied = { ...entry("three", "carol", 1, null), received_at_ms: 123 };
    expect(await post(stub, "/commit", plan("receipt-log", 2, 0, [supplied])))
      .toEqual({ status: 400, json: { ok: false, error: { code: "malformed_request" } } });
    expect(await inspect(stub)).toEqual(beforeRejected);
  });

  it("serves a realistic append and merge in exactly one read-set plus one commit each", async () => {
    const stub = realmStub();
    await createLog(stub, "append-log");
    const append = await logicalCommit(stub, "append-log", [entry("a1", "alice", 1, null)]);
    expect(append.requests).toEqual(["/read-set", "/commit"]);
    expect(append.result).toEqual({ status: 200, json: { ok: true, revision: 1 } });

    await createLog(stub, "merge-log");
    const merge = await logicalCommit(stub, "merge-log", [
      entry("a-remote", "alice", 1, null),
      entry("b-remote", "bob", 1, null),
    ]);
    expect(merge.requests).toEqual(["/read-set", "/commit"]);
    expect(merge.result).toEqual({ status: 200, json: { ok: true, revision: 1 } });
  });

  it("stores every indexed entry column in agreement with its own canonical bytes", async () => {
    const stub = realmStub();
    await createLog(stub, "columns-log");
    const inserted = entry("entry-columns", "writer-columns", 7, "entry-six", "2026-08-23T23:45:01Z");
    expect((await post(stub, "/commit", plan("columns-log", 0, 0, [inserted]))).status).toBe(200);

    const stored = (await inspect(stub)).entries[0];
    const ownBytes = JSON.parse(stored.canonical_json);
    expect({
      entry_id: stored.entry_id,
      writer_id: stored.writer_id,
      writer_seq: stored.writer_seq,
      prev_entry_id: stored.prev_entry_id,
      created_at: stored.created_at,
    }).toEqual({
      entry_id: ownBytes.entry_id,
      writer_id: ownBytes.writer_id,
      writer_seq: ownBytes.writer_seq,
      prev_entry_id: ownBytes.prev_entry_id,
      created_at: ownBytes.created_at,
    });
  });

  it("keeps two logs in one realm isolated through the HTTP surface", async () => {
    const stub = realmStub();
    await createLog(stub, "log-a");
    await createLog(stub, "log-b");
    await post(stub, "/commit", plan("log-a", 0, 0, [entry("a1", "writer", 1, null)]));
    await post(stub, "/commit", plan("log-b", 0, 0, [entry("b1", "writer", 1, null)]));

    const a = await post(stub, "/read-set", {
      log_id: "log-a", writers: ["writer"],
      coordinates: [{ writer_id: "writer", writer_seq: 1 }], entry_ids: ["a1", "b1"],
    });
    const b = await post(stub, "/frontier", { log_id: "log-b" });
    expect(a).toEqual({ status: 200, json: { ok: true, read_set: {
      log_id: "log-a", format_version: 1, revision: 1, lease_epoch: 0,
      tips: [{ writer_id: "writer", last_seq: 1, last_entry_id: "a1" }],
      coordinates: [{ writer_id: "writer", writer_seq: 1,
        canonical_bytes: entry("a1", "writer", 1, null).canonical_bytes }],
      entry_ids: [{ entry_id: "a1", canonical_bytes: entry("a1", "writer", 1, null).canonical_bytes }],
    } } });
    expect(b.json.frontier.writers).toEqual([{ writer_id: "writer", seq: 1, entry_id: "b1" }]);
  });

  it("returns distinct stale_revision and obsolete_epoch errors and writes no rows", async () => {
    const staleStub = realmStub();
    await createLog(staleStub, "stale-log");
    await post(staleStub, "/commit", plan("stale-log", 0, 0, [entry("seed", "alice", 1, null)]));
    const beforeStale = JSON.stringify(await inspect(staleStub));
    const stale = await post(staleStub, "/commit", plan("stale-log", 0, 0, [entry("stale", "bob", 1, null)]));
    expect(stale).toEqual({ status: 409, json: { ok: false, error: { code: "stale_revision" } } });
    expect(JSON.stringify(await inspect(staleStub))).toBe(beforeStale);

    const epochStub = realmStub();
    await createLog(epochStub, "epoch-log");
    await runInDurableObject(epochStub, (_instance, state) => {
      new RealmStore(state.storage.sql, state.storage).takeLease("epoch-log");
    });
    const beforeEpoch = JSON.stringify(await inspect(epochStub));
    const obsolete = await post(epochStub, "/commit", plan("epoch-log", 0, 0, [entry("old", "alice", 1, null)]));
    expect(obsolete).toEqual({ status: 409, json: { ok: false, error: { code: "obsolete_epoch" } } });
    expect(JSON.stringify(await inspect(epochStub))).toBe(beforeEpoch);
  });

  it("an unknown-log read is not-found and creates neither schema nor rows", async () => {
    const stub = realmStub();
    const before = await runInDurableObject(stub, (_instance, state) => ({
      catalog: state.storage.sql.exec("SELECT name, type, sql FROM sqlite_master ORDER BY name").toArray(),
      counts: state.storage.sql.exec("SELECT total_changes() AS n").one().n,
    }));
    const response = await post(stub, "/read-set", {
      log_id: "missing", writers: [], coordinates: [], entry_ids: [],
    });
    expect(response).toEqual({ status: 404, json: { ok: false, error: { code: "not_found" } } });
    const after = await runInDurableObject(stub, (_instance, state) => ({
      catalog: state.storage.sql.exec("SELECT name, type, sql FROM sqlite_master ORDER BY name").toArray(),
      counts: state.storage.sql.exec("SELECT total_changes() AS n").one().n,
    }));
    expect(after).toEqual(before);

    const initialized = realmStub();
    await createLog(initialized, "known");
    const initializedBefore = await runInDurableObject(initialized, (_instance, state) => ({
      catalog: state.storage.sql.exec("SELECT name, type, sql FROM sqlite_master ORDER BY name").toArray(),
      counts: {
        logs: state.storage.sql.exec("SELECT COUNT(*) AS n FROM logs").one().n,
        entries: state.storage.sql.exec("SELECT COUNT(*) AS n FROM entries").one().n,
        tips: state.storage.sql.exec("SELECT COUNT(*) AS n FROM writer_tips").one().n,
      },
    }));
    expect(await post(initialized, "/read-set", {
      log_id: "still-missing", writers: [], coordinates: [], entry_ids: [],
    })).toEqual({ status: 404, json: { ok: false, error: { code: "not_found" } } });
    const initializedAfter = await runInDurableObject(initialized, (_instance, state) => ({
      catalog: state.storage.sql.exec("SELECT name, type, sql FROM sqlite_master ORDER BY name").toArray(),
      counts: {
        logs: state.storage.sql.exec("SELECT COUNT(*) AS n FROM logs").one().n,
        entries: state.storage.sql.exec("SELECT COUNT(*) AS n FROM entries").one().n,
        tips: state.storage.sql.exec("SELECT COUNT(*) AS n FROM writer_tips").one().n,
      },
    }));
    expect(initializedAfter).toEqual(initializedBefore);
  });

  it("rejects malformed bodies before they can do damage", async () => {
    const stub = realmStub();
    await createLog(stub, "safe-log");
    const before = JSON.stringify(await inspect(stub));
    const badJsonResponse = await stub.fetch("https://realm.invalid/commit", {
      method: "POST", headers: { "content-type": "application/json" }, body: "{",
    });
    expect(badJsonResponse.status).toBe(400);
    expect(await badJsonResponse.json()).toEqual({ ok: false, error: { code: "malformed_request" } });
    expect((await post(stub, "/commit", {
      ...plan("safe-log", 0, 0, [entry("bad", "writer", 1, null)]),
      expected_revision: "0",
    })).status).toBe(400);
    expect(JSON.stringify(await inspect(stub))).toBe(before);
  });

  it("reports a fork-shaped commit only as a storage constraint", async () => {
    const stub = realmStub();
    await createLog(stub, "fork-log");
    await post(stub, "/commit", plan("fork-log", 0, 0, [entry("first", "alice", 1, null)]));
    const response = await post(stub, "/commit", plan("fork-log", 1, 0, [entry("fork", "alice", 1, null)]));
    expect(response).toEqual({ status: 409, json: { ok: false, error: { code: "constraint_violation" } } });
    expect(JSON.stringify(response)).not.toContain("writer_fork");
    expect((await inspect(stub)).entries.map((row: JsonObject) => row.entry_id)).toEqual(["first"]);
  });

  it("exposes the pinned read routes with the RealmStore page shapes", async () => {
    const stub = realmStub();
    await createLog(stub, "reads-log");
    await post(stub, "/commit", plan("reads-log", 0, 0, [
      entry("one", "alice", 1, null), entry("two", "alice", 2, "one"),
    ]));
    expect((await post(stub, "/read-writer", {
      log_id: "reads-log", writer_id: "alice", after_seq: 0, through_seq: 2, limit: 1,
    })).json.page.next_after_seq).toBe(1);
    expect((await post(stub, "/tail-local", {
      log_id: "reads-log", after_arrival: 0, limit: 1,
    })).json.page.next_after_arrival).toEqual(expect.any(Number));
  });

  it("pins storage_full on the wire as a mapping, not an exercised disk-full behavior", async () => {
    const throwingStore = {
      commit(): never { throw new RealmStoreError("storage_full"); },
    } as unknown as RealmStore;
    const response = await handleRealmRequest(new Request("https://realm.invalid/commit", {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(plan("full-log", 0, 0, [])),
    }), throwingStore);
    expect(response.status).toBe(507);
    expect(await response.json()).toEqual({ ok: false, error: { code: "storage_full" } });
  });
});
