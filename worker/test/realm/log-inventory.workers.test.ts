import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { canonicalize } from "../../src/jcs";
import { initSchema } from "../../src/realm/schema";
import { REALM_CREATE_HEADER, REALM_ID_HEADER } from "../../src/realm/realm_auth";

type Json = Record<string, any>;
type StorageInstance = { storageFetch(request: Request): Promise<Response> };

const LOG_A = "61000000-0000-4000-8000-000000000001";
const LOG_B = "61000000-0000-4000-8000-000000000002";
const LOG_C = "61000000-0000-4000-8000-000000000003";
const WRITER_B = "61000000-0000-4000-8000-000000000011";
const ENTRY_B = "61000000-0000-4000-8000-000000000021";
const ARCHIVE_B = "61000000-0000-4000-8000-000000000031";

let sequence = 0;

function stub(name: string): DurableObjectStub {
  const id = env.REALM_CONTAINER.idFromName(`inventory-${name}-${Date.now()}-${sequence++}`);
  return env.REALM_CONTAINER.get(id);
}

function base64(value: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < value.length; offset += 16_384) {
    binary += String.fromCharCode(...value.subarray(offset, offset + 16_384));
  }
  return btoa(binary);
}

function entry(
  logId: string,
  writerId: string,
  entryId: string,
  writerSeq: number,
  previous: string | null,
): string {
  return base64(canonicalize({
    version: 1,
    log_id: logId,
    entry_id: entryId,
    writer_id: writerId,
    writer_seq: writerSeq,
    prev_entry_id: previous,
    created_at: `2026-09-12T00:00:0${writerSeq}Z`,
    body: { inventory: entryId },
  }));
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
      {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify(body),
      },
    ));
    return { status: response.status, json: await response.json() as Json };
  });
}

async function list(target: DurableObjectStub): Promise<{ status: number; json: Json }> {
  return await internal(target, "/list-logs", { max_logs: 64 });
}

function restoreBody() {
  return {
    bundle_id: "inventory-bundle",
    max_logs: 1,
    logs: [{
      log_id: LOG_B,
      archive_id: ARCHIVE_B,
      writer_id: WRITER_B,
      entries: [entry(LOG_B, WRITER_B, ENTRY_B, 1, null)],
    }],
  };
}

describe("internal log inventory wire", () => {
  it("lists every mixed log type internally while public routing stays closed", async () => {
    const target = stub("mixed");
    const secret = await createRealm(target);

    const unauthenticated = await target.fetch("https://realm.invalid/list-logs", {
      method: "POST",
      body: JSON.stringify({ max_logs: 64 }),
      headers: { "content-type": "application/json" },
    });
    expect(unauthenticated.status).toBe(401);
    expect(await unauthenticated.json()).toEqual({ ok: false, error: { code: "unauthorized" } });

    const authenticated = await target.fetch("https://realm.invalid/list-logs", {
      method: "POST",
      body: JSON.stringify({ max_logs: 64 }),
      headers: { "content-type": "application/json", authorization: `Bearer ${secret}` },
    });
    expect(authenticated.status).toBe(404);
    expect(await authenticated.json()).toEqual({ ok: false, error: { code: "not_found" } });

    expect(await internal(target, "/restore-bundle-batch", restoreBody())).toEqual({
      status: 200,
      json: { ok: true, result: { imported_logs: 1, skipped_logs: 0, complete: true } },
    });
    expect(await internal(target, "/create-log", {
      log_id: LOG_A,
      format_version: 1,
      created_at: "2026-09-12T00:00:00Z",
    })).toEqual({ status: 201, json: { ok: true } });

    const lease = await internal(target, "/take-lease", { log_id: LOG_A });
    expect(lease.status).toBe(200);
    const writerA = lease.json.writer_id;
    const entryA = entry(LOG_A, writerA, "61000000-0000-4000-8000-000000000041", 1, null);
    expect(await internal(target, "/commit", {
      log_id: LOG_A,
      expected_revision: 0,
      expected_epoch: lease.json.lease_epoch,
      insert_entries: [{
        log_id: LOG_A,
        entry_id: "61000000-0000-4000-8000-000000000041",
        writer_id: writerA,
        writer_seq: 1,
        prev_entry_id: null,
        created_at: "2026-09-12T00:00:01Z",
        canonical_bytes: entryA,
      }],
      put_tips: [{ writer_id: writerA, last_seq: 1, last_entry_id: "61000000-0000-4000-8000-000000000041" }],
    })).toEqual({ status: 200, json: { ok: true, revision: 1 } });

    const snapshot = await list(target);
    expect(snapshot.status).toBe(200);
    expect(Object.keys(snapshot.json)).toEqual(["ok", "result"]);
    expect(snapshot.json.result.logs.map((log: Json) => log.log_id)).toEqual([LOG_A, LOG_B]);
    expect(snapshot.json.result.logs.every((log: Json) => Object.keys(log).sort().join(",") ===
      "created_at,document_writer_id,format_version,log_id,revision,writers")).toBe(true);
    expect(snapshot.json.result.logs[0].writers).toHaveLength(1);
    expect(snapshot.json.result.logs[1].writers).toEqual([{
      writer_id: WRITER_B,
      last_seq: 1,
      last_entry_id: ENTRY_B,
    }]);
    expect(snapshot.json.result.generation).toMatch(/^[0-9a-f]{64}$/);
    expect(JSON.stringify(snapshot.json)).not.toContain("secret_hash");
    expect(JSON.stringify(snapshot.json)).not.toContain(secret);

    expect(await internal(target, "/create-log", {
      log_id: LOG_C,
      format_version: 1,
      created_at: "2026-09-12T00:00:00Z",
    })).toEqual({ status: 201, json: { ok: true } });
    const afterCreate = await list(target);
    expect(afterCreate.json.result.generation).not.toBe(snapshot.json.result.generation);

    const secondLease = await internal(target, "/take-lease", { log_id: LOG_A });
    expect(secondLease.status).toBe(200);
    const entryA2Id = "61000000-0000-4000-8000-000000000042";
    const entryA2 = entry(LOG_A, secondLease.json.writer_id, entryA2Id, 2,
      "61000000-0000-4000-8000-000000000041");
    expect(await internal(target, "/commit", {
      log_id: LOG_A,
      expected_revision: 1,
      expected_epoch: secondLease.json.lease_epoch,
      insert_entries: [{
        log_id: LOG_A,
        entry_id: entryA2Id,
        writer_id: secondLease.json.writer_id,
        writer_seq: 2,
        prev_entry_id: "61000000-0000-4000-8000-000000000041",
        created_at: "2026-09-12T00:00:02Z",
        canonical_bytes: entryA2,
      }],
      put_tips: [{ writer_id: secondLease.json.writer_id, last_seq: 2, last_entry_id: entryA2Id }],
    })).toEqual({ status: 200, json: { ok: true, revision: 2 } });
    const afterCommit = await list(target);
    expect(afterCommit.json.result.generation).not.toBe(afterCreate.json.result.generation);
  });

  it("returns an empty provisioned catalog without creating storage tables", async () => {
    const target = stub("empty");
    await createRealm(target);
    const before = await runInDurableObject(target, (_instance, state) =>
      state.storage.sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").toArray());
    expect(await list(target)).toEqual({
      status: 200,
      json: { ok: true, result: { generation: expect.stringMatching(/^[0-9a-f]{64}$/), logs: [] } },
    });
    const after = await runInDurableObject(target, (_instance, state) =>
      state.storage.sql.exec("SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name").toArray());
    expect(after).toEqual(before);
  });

  it("refuses count and metadata byte bounds before materializing inventory", async () => {
    const countTarget = stub("count-bound");
    await createRealm(countTarget);
    await runInDurableObject(countTarget, (_instance, state) => {
      initSchema(state.storage.sql);
      for (let index = 0; index < 65; index += 1) {
        const suffix = String(index + 1).padStart(12, "0");
        state.storage.sql.exec(
          "INSERT INTO logs (log_id, format_version, revision, created_at, lease_epoch, document_writer_id) VALUES (?, 1, 0, ?, 0, NULL)",
          `62000000-0000-4000-8000-${suffix}`,
          "2026-09-12T00:00:00Z",
        );
      }
    });
    expect(await list(countTarget)).toEqual({ status: 413, json: { ok: false, error: { code: "oversize" } } });

    const bytesTarget = stub("bytes-bound");
    await createRealm(bytesTarget);
    await runInDurableObject(bytesTarget, (_instance, state) => {
      initSchema(state.storage.sql);
      state.storage.sql.exec(
        "INSERT INTO logs (log_id, format_version, revision, created_at, lease_epoch, document_writer_id) VALUES (?, 1, 0, ?, 0, NULL)",
        LOG_A,
        "2026-09-12T00:00:00Z",
      );
      state.storage.sql.exec(
        "INSERT INTO writer_tips (log_id, writer_id, last_seq, last_entry_id) VALUES (?, ?, 1, ?)",
        LOG_A,
        "w".repeat(300_000),
        ENTRY_B,
      );
    });
    expect(await list(bytesTarget)).toEqual({ status: 413, json: { ok: false, error: { code: "oversize" } } });

    const metadataTarget = stub("metadata-bound");
    await createRealm(metadataTarget);
    await runInDurableObject(metadataTarget, (_instance, state) => {
      initSchema(state.storage.sql);
      state.storage.sql.exec(
        "INSERT INTO logs (log_id, format_version, revision, created_at, lease_epoch, document_writer_id) VALUES (?, 1, 0, ?, 0, NULL)",
        LOG_A,
        "é".repeat(140_000),
      );
    });
    expect(await list(metadataTarget)).toEqual({ status: 413, json: { ok: false, error: { code: "oversize" } } });

    const malformedTarget = stub("malformed-metadata");
    await createRealm(malformedTarget);
    await runInDurableObject(malformedTarget, (_instance, state) => {
      initSchema(state.storage.sql);
      state.storage.sql.exec(
        "INSERT INTO logs (log_id, format_version, revision, created_at, lease_epoch, document_writer_id) VALUES (?, 0, 0, ?, 0, NULL)",
        LOG_A,
        "2026-09-12T00:00:00Z",
      );
    });
    expect(await list(malformedTarget)).toEqual({ status: 409, json: { ok: false, error: { code: "constraint" } } });
  });

  it("fails closed for pending restore and orphan storage rows", async () => {
    const pending = stub("pending");
    await createRealm(pending);
    const pendingBody = {
      ...restoreBody(),
      logs: [restoreBody().logs[0], {
        log_id: LOG_C,
        archive_id: "61000000-0000-4000-8000-000000000032",
        writer_id: "61000000-0000-4000-8000-000000000012",
        entries: [entry(LOG_C, "61000000-0000-4000-8000-000000000012", "61000000-0000-4000-8000-000000000022", 1, null)],
      }],
    };
    expect((await internal(pending, "/restore-bundle-batch", pendingBody)).json.result.complete).toBe(false);
    expect(await list(pending)).toEqual({ status: 409, json: { ok: false, error: { code: "obsolete_epoch" } } });

    const orphan = stub("orphan");
    await createRealm(orphan);
    await runInDurableObject(orphan, (_instance, state) => {
      initSchema(state.storage.sql);
      state.storage.sql.exec(
        "INSERT INTO writer_tips (log_id, writer_id, last_seq, last_entry_id) VALUES (?, ?, 1, ?)",
        LOG_A,
        WRITER_B,
        ENTRY_B,
      );
      state.storage.sql.exec(
        "INSERT INTO restore_markers (log_id, archive_id, writer_id, entry_count, total_bytes, manifest_json, state) VALUES (?, ?, ?, 1, 1, ?, 'complete')",
        LOG_C,
        ARCHIVE_B,
        WRITER_B,
        new Uint8Array([1]),
      );
    });
    expect(await list(orphan)).toEqual({ status: 409, json: { ok: false, error: { code: "constraint" } } });
  });
});
