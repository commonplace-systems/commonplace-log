import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { canonicalize } from "../../src/jcs";

type Json = Record<string, any>;
type Snapshot = { logs: Json[]; entries: Json[]; bundles: Json[] };

const DEPLOYMENT_TOKEN = "test-gateway-token";
const LOG_ID = "57000000-0000-4000-8000-000000000001";
const WRITER_ID = "57000000-0000-4000-8000-000000000011";
const ARCHIVE_ID = "57000000-0000-4000-8000-000000000021";
const ENTRY_ID = "57000000-0000-4000-8000-000000000031";
const MAX_RAW_BODY_BYTES = 32 * 1024 * 1024;

function realmName(): string {
  return crypto.randomUUID();
}

function gatewayFetch(path: string, init: RequestInit = {}, token: string | null = DEPLOYMENT_TOKEN) {
  const headers = new Headers(init.headers);
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return SELF.fetch(`https://gateway.invalid${path}`, { ...init, headers });
}

async function createRealm(realmId: string): Promise<string> {
  const response = await gatewayFetch(`/realms/${realmId}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: "{}",
  });
  expect(response.status).toBe(201);
  const body = await response.json() as Json;
  if (body.realm_id !== realmId || typeof body.realm_secret !== "string" || body.realm_secret.length !== 64) {
    throw new Error("realm creation returned an invalid secret shape");
  }
  return body.realm_secret;
}

async function realmPost(realmId: string, path: string, body: unknown, token: string) {
  const response = await gatewayFetch(`/realms/${realmId}${path}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }, token);
  return { status: response.status, json: await response.json() as Json };
}

function base64(value: Uint8Array): string {
  let binary = "";
  for (let offset = 0; offset < value.length; offset += 16_384) {
    binary += String.fromCharCode(...value.subarray(offset, offset + 16_384));
  }
  return btoa(binary);
}

function bundle() {
  return {
    bundle_id: "public-buffering-bundle-1",
    max_logs: 1,
    logs: [{
      log_id: LOG_ID,
      archive_id: ARCHIVE_ID,
      writer_id: WRITER_ID,
      entries: [base64(canonicalize({
        version: 1,
        log_id: LOG_ID,
        entry_id: ENTRY_ID,
        writer_id: WRITER_ID,
        writer_seq: 1,
        prev_entry_id: null,
        created_at: "2026-09-13T00:00:01Z",
        body: { public_buffering: true },
      }))],
    }],
  };
}

async function snapshot(realmId: string): Promise<Snapshot> {
  const target = env.REALM_CONTAINER.getByName(realmId);
  return await runInDurableObject(target, (_instance, state) => {
    const hasTable = (name: string): boolean => state.storage.sql
      .exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", name).toArray().length > 0;
    const rows = (name: string, query: string): any[] => hasTable(name) ? state.storage.sql.exec(query).toArray() : [];

    return {
      logs: rows("logs", "SELECT log_id, revision FROM logs ORDER BY log_id"),
      entries: rows("entries", "SELECT log_id, entry_id, canonical_json FROM entries ORDER BY log_id, writer_seq")
        .map((row) => ({
          log_id: String(row.log_id),
          entry_id: String(row.entry_id),
          bytes: Array.from(new Uint8Array(row.canonical_json as ArrayBuffer)),
        })),
      bundles: rows("restore_bundles", "SELECT bundle_id, state FROM restore_bundles ORDER BY singleton"),
    };
  });
}

describe("public ingress body buffering", () => {
  it("rejects wrong-secret bodies, then serves inventory and restore, while bounding overflow before auth", async () => {
    const realm = realmName();
    const secret = await createRealm(realm);

    const wrong = await realmPost(realm, "/list-logs", { max_logs: 64 }, "wrong-realm-secret");
    expect(wrong).toEqual({ status: 401, json: { ok: false, error: { code: "unauthorized" } } });

    const inventory = await realmPost(realm, "/list-logs", { max_logs: 64 }, secret);
    expect(inventory.status).toBe(200);
    expect(inventory.json.ok).toBe(true);
    expect(inventory.json.result.logs).toEqual([]);

    const restored = await realmPost(realm, "/restore-bundle-batch", bundle(), secret);
    expect(restored).toEqual({
      status: 200,
      json: { ok: true, result: { imported_logs: 1, skipped_logs: 0, complete: true } },
    });
    const beforeOverflow = await snapshot(realm);

    const oversized = await gatewayFetch(`/realms/${realm}/list-logs`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "x".repeat(MAX_RAW_BODY_BYTES + 1),
    }, "wrong-realm-secret");
    expect(oversized.status).toBe(413);
    expect(await oversized.json()).toEqual({ ok: false, error: { code: "oversize" } });
    expect(await snapshot(realm)).toEqual(beforeOverflow);
  });
});
