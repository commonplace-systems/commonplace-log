import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { canonicalize } from "../../src/jcs";
import { REALM_CREATE_HEADER, REALM_ID_HEADER } from "../../src/realm/realm_auth";
import { storageInternal, type StorageInternalEnv } from "../../src/realm/outbound";

type Json = Record<string, any>;
type StorageInstance = { storageFetch(request: Request): Promise<Response> };
const LOG_A = "51000000-0000-4000-8000-000000000001";
const LOG_B = "51000000-0000-4000-8000-000000000002";
const WRITER_A = "51000000-0000-4000-8000-000000000011";
const WRITER_B = "51000000-0000-4000-8000-000000000012";
const ARCHIVE_A = "51000000-0000-4000-8000-000000000021";
const ARCHIVE_B = "51000000-0000-4000-8000-000000000022";
const ENTRY_A1 = "51000000-0000-4000-8000-000000000031";
const ENTRY_A2 = "51000000-0000-4000-8000-000000000032";
const ENTRY_B1 = "51000000-0000-4000-8000-000000000033";
const ENTRY_B2 = "51000000-0000-4000-8000-000000000034";

let sequence = 0;

function stub(name = "wire"): DurableObjectStub {
  const id = env.REALM_CONTAINER.idFromName(`restore-wire-${name}-${Date.now()}-${sequence++}`);
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
  prevEntryId: string | null,
  body = entryId,
): string {
  return base64(canonicalize({
    version: 1,
    log_id: logId,
    entry_id: entryId,
    writer_id: writerId,
    writer_seq: writerSeq,
    prev_entry_id: prevEntryId,
    created_at: `2026-09-12T00:00:0${writerSeq}Z`,
    body: { wire: body },
  }));
}

function bundle() {
  return {
    bundle_id: "wire-bundle-1",
    max_logs: 1,
    logs: [
      {
        log_id: LOG_A,
        archive_id: ARCHIVE_A,
        writer_id: WRITER_A,
        entries: [entry(LOG_A, WRITER_A, ENTRY_A1, 1, null), entry(LOG_A, WRITER_A, ENTRY_A2, 2, ENTRY_A1)],
      },
      {
        log_id: LOG_B,
        archive_id: ARCHIVE_B,
        writer_id: WRITER_B,
        entries: [entry(LOG_B, WRITER_B, ENTRY_B1, 1, null), entry(LOG_B, WRITER_B, ENTRY_B2, 2, ENTRY_B1)],
      },
    ],
  };
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

async function internal(target: DurableObjectStub, body: unknown, init: RequestInit = {}): Promise<{ status: number; json: Json }> {
  const response = await runInDurableObject(target, async (instance) => {
    const result = await (instance as unknown as StorageInstance).storageFetch(new Request("https://storage.internal/restore-bundle-batch", {
      method: "POST",
      headers: { "content-type": "application/json", ...(init.headers ?? {}) },
      body: JSON.stringify(body),
      ...init,
    }));
    return { status: result.status, json: await result.json() as Json };
  });
  return response;
}

async function sqlSnapshot(target: DurableObjectStub): Promise<Json> {
  return await runInDurableObject(target, (_instance, state) => {
    const hasTable = (name: string): boolean => state.storage.sql
      .exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", name).toArray().length > 0;
    const rows = (name: string, query: string): any[] => hasTable(name) ? state.storage.sql.exec(query).toArray() : [];
    return {
    logs: rows("logs", "SELECT log_id, revision FROM logs ORDER BY log_id"),
    entries: rows("entries", "SELECT log_id, entry_id, canonical_json FROM entries ORDER BY log_id, writer_seq")
      .map((row) => ({ log_id: row.log_id, entry_id: row.entry_id, bytes: Array.from(new Uint8Array(row.canonical_json as ArrayBuffer)) })),
    bundles: rows("restore_bundles", "SELECT bundle_id, state FROM restore_bundles ORDER BY singleton"),
    };
  });
}

describe("restore bundle wire", () => {
  it("requires realm authorization before accepting the bounded public restore route", async () => {
    const target = stub("public");
    const secret = await createRealm(target);
    const body = bundle();
    const unauthenticated = await target.fetch("https://realm.invalid/restore-bundle-batch", {
      method: "POST", body: JSON.stringify(body), headers: { "content-type": "application/json" },
    });
    expect(unauthenticated.status).toBe(401);
    expect(await unauthenticated.json()).toEqual({ ok: false, error: { code: "unauthorized" } });
    const authenticated = await target.fetch("https://realm.invalid/restore-bundle-batch", {
      method: "POST", body: JSON.stringify(body),
      headers: { "content-type": "application/json", authorization: `Bearer ${secret}` },
    });
    expect(authenticated.status).toBe(200);
    expect(await authenticated.json()).toEqual({
      ok: true,
      result: { imported_logs: 1, skipped_logs: 0, complete: false },
    });
  });

  it("imports the full sorted inventory in bounded batches and resumes after a DO restart", async () => {
    const target = stub("resume");
    await createRealm(target);
    const source = bundle();
    expect(await internal(target, source)).toEqual({ status: 200, json: {
      ok: true, result: { imported_logs: 1, skipped_logs: 0, complete: false },
    } });
    await expect(runInDurableObject(target, async (_instance, state) => {
      await state.storage.sync();
      state.abort("wire restart");
    })).rejects.toThrow("wire restart");
    const resumed = env.REALM_CONTAINER.get(target.id);
    expect(await internal(resumed, source)).toEqual({ status: 200, json: {
      ok: true, result: { imported_logs: 1, skipped_logs: 1, complete: true },
    } });
    const snapshot = await sqlSnapshot(resumed);
    expect(snapshot.entries).toHaveLength(4);
    expect(snapshot.bundles).toEqual([{ bundle_id: "wire-bundle-1", state: "complete" }]);
    const expected = source.logs.flatMap((log) => log.entries.map((value) => ({ log_id: log.log_id, bytes: Array.from(Uint8Array.from(atob(value), (char) => char.charCodeAt(0))) })));
    expect(snapshot.entries.map((row: Json) => ({ log_id: row.log_id, bytes: row.bytes }))).toEqual(expected);
  });

  it("refuses unprovisioned, nonempty, and target-confused requests without mutation", async () => {
    const unprovisioned = stub("unprovisioned");
    expect((await internal(unprovisioned, bundle())).status).toBe(409);

    const nonempty = stub("nonempty");
    await createRealm(nonempty);
    const createLog = await runInDurableObject(nonempty, async (instance) => {
      const response = await (instance as unknown as StorageInstance).storageFetch(new Request("https://storage.internal/create-log", {
        method: "POST", body: JSON.stringify({ log_id: LOG_A }), headers: { "content-type": "application/json" },
      }));
      return { status: response.status, json: await response.json() as Json };
    });
    expect(createLog).toEqual({ status: 201, json: { ok: true } });
    const before = await sqlSnapshot(nonempty);
    expect((await internal(nonempty, bundle())).status).toBe(409);
    expect(await sqlSnapshot(nonempty)).toEqual(before);

    const confused = stub("confused");
    await createRealm(confused);
    const invalid = { ...bundle(), realm_id: "attacker-selected-target" };
    expect((await internal(confused, invalid)).json).toEqual({ ok: false, error: { code: "malformed" } });
    expect((await sqlSnapshot(confused)).bundles).toEqual([]);
  });

  it("uses the platform container identity for the internal outbound seam", async () => {
    const target = stub("outbound-a");
    const other = stub("outbound-b");
    await createRealm(target);
    await createRealm(other);
    const otherBefore = await sqlSnapshot(other);
    const selected: string[] = [];
    const targets = new Map([["container-a", target], ["container-b", other]]);
    const fake: StorageInternalEnv<{ value: string }> = {
      REALM_NODE: {
        idFromString(value) { selected.push(value); return { value }; },
        get(id) {
          const selectedTarget = targets.get(id.value);
          if (selectedTarget === undefined) throw new Error("unknown test target");
          return { async storageFetch(request) {
            const url = request.url;
            const method = request.method;
            const headers = [...request.headers];
            const body = request.body === null ? null : await request.arrayBuffer();
            if (body !== null && body.byteLength > 32 * 1024 * 1024) throw new Error("request body exceeds wire limit");
            const result = await runInDurableObject(selectedTarget, async (instance) => {
              const forwarded = new Request(url, {
                method,
                headers,
                body: body === null ? undefined : body,
              });
              const response = await (instance as unknown as StorageInstance).storageFetch(forwarded);
              return { status: response.status, headers: [...response.headers], text: await response.text() };
            });
            return new Response(result.text, { status: result.status, headers: result.headers });
          } };
        },
      },
    };
    const response = await storageInternal(new Request("https://storage.internal/restore-bundle-batch?realm_id=container-b", {
      method: "POST", body: JSON.stringify(bundle()),
      headers: { "content-type": "application/json", "x-realm-id": "container-b" },
    }), fake, { containerId: "container-a", className: "RealmNode" });
    expect(response.status).toBe(200);
    expect(selected).toEqual(["container-a"]);
    expect((await sqlSnapshot(target)).bundles).toEqual([{ bundle_id: "wire-bundle-1", state: "pending" }]);
    expect(await sqlSnapshot(other)).toEqual(otherBefore);
  });

  it("returns closed malformed, raw-body, and decoded-size errors", async () => {
    const target = stub("limits");
    await createRealm(target);
    expect((await internal(target, { ...bundle(), logs: [{ ...bundle().logs[0], entries: ["AB=="] }] })).json)
      .toEqual({ ok: false, error: { code: "malformed" } });

    const rawResult = await runInDurableObject(target, async (instance) => {
      let cancelled = false;
      const chunk = new Uint8Array(1024 * 1024);
      let sent = 0;
      const raw = new ReadableStream<Uint8Array>({
        pull(controller) {
          if (sent === 33) { controller.close(); return; }
          controller.enqueue(chunk);
          sent += 1;
        },
        cancel() { cancelled = true; },
      });
      const rawResponse = await (instance as unknown as StorageInstance).storageFetch(new Request("https://storage.internal/restore-bundle-batch", {
        method: "POST", body: raw, duplex: "half", headers: { "content-type": "application/json" },
      } as RequestInit & { duplex: "half" }));
      return { status: rawResponse.status, json: await rawResponse.json() as Json, cancelled };
    });
    expect(rawResult).toEqual({ status: 413, json: { ok: false, error: { code: "oversize" } }, cancelled: true });

    const logs = Array.from({ length: 17 }, (_, index) => {
      const logId = `52000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`;
      const writerId = `53000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`;
      const entryId = `54000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`;
      return { log_id: logId, archive_id: `55000000-0000-4000-8000-${String(index + 1).padStart(12, "0")}`, writer_id: writerId,
        entries: [entry(logId, writerId, entryId, 1, null, "x".repeat(1_000_000))] };
    });
    const decodedResponse = await internal(target, { bundle_id: "wire-too-large", max_logs: 64, logs });
    expect(decodedResponse).toEqual({ status: 413, json: { ok: false, error: { code: "oversize" } } });
    expect((await sqlSnapshot(target)).bundles).toEqual([]);
  });
});
