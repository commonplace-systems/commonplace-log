import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { canonicalize } from "../../src/jcs";

type Json = Record<string, any>;
type Snapshot = {
  logs: Json[];
  entries: Json[];
  bundles: Json[];
};

const DEPLOYMENT_TOKEN = "test-gateway-token";
const LOG_ID = "56000000-0000-4000-8000-000000000001";
const WRITER_ID = "56000000-0000-4000-8000-000000000011";
const ARCHIVE_ID = "56000000-0000-4000-8000-000000000021";
const ENTRY_1 = "56000000-0000-4000-8000-000000000031";
const ENTRY_2 = "56000000-0000-4000-8000-000000000032";
const UNRELATED_LOG_ID = "56000000-0000-4000-8000-000000000099";

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

async function realmPost(
  realmId: string,
  path: string,
  body: unknown,
  token: string | null,
): Promise<{ status: number; json: Json }> {
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

function encodedEntry(entryId: string, writerSeq: number, prevEntryId: string | null): string {
  return base64(canonicalize({
    version: 1,
    log_id: LOG_ID,
    entry_id: entryId,
    writer_id: WRITER_ID,
    writer_seq: writerSeq,
    prev_entry_id: prevEntryId,
    created_at: `2026-09-13T00:00:0${writerSeq}Z`,
    body: { public_restore: entryId },
  }));
}

function bundle() {
  return {
    bundle_id: "public-restore-bundle-1",
    max_logs: 1,
    logs: [{
      log_id: LOG_ID,
      archive_id: ARCHIVE_ID,
      writer_id: WRITER_ID,
      entries: [
        encodedEntry(ENTRY_1, 1, null),
        encodedEntry(ENTRY_2, 2, ENTRY_1),
      ],
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

describe("authenticated public restore wire", () => {
  it("rejects missing, wrong, cross-realm, and deployment tokens before mutation", async () => {
    const realmA = realmName();
    const realmB = realmName();
    await createRealm(realmA);
    const secretB = await createRealm(realmB);
    const beforeA = await snapshot(realmA);
    const beforeB = await snapshot(realmB);

    for (const token of [null, "obvious-wrong-realm-secret", secretB, DEPLOYMENT_TOKEN]) {
      const response = await realmPost(realmA, "/restore-bundle-batch", bundle(), token);
      expect(response.status).toBe(401);
      expect(response.json).toEqual({ ok: false, error: { code: "unauthorized" } });
    }

    const listResponse = await realmPost(realmA, "/list-logs", { max_logs: 64 }, secretB);
    expect(listResponse.status).toBe(401);
    expect(listResponse.json).toEqual({ ok: false, error: { code: "unauthorized" } });
    expect(await snapshot(realmA)).toEqual(beforeA);
    expect(await snapshot(realmB)).toEqual(beforeB);
  });

  it("restores through public auth with exact bytes and idempotent replay", async () => {
    const realm = realmName();
    const secret = await createRealm(realm);
    const source = bundle();

    const first = await realmPost(realm, "/restore-bundle-batch", source, secret);
    expect(first).toEqual({
      status: 200,
      json: { ok: true, result: { imported_logs: 1, skipped_logs: 0, complete: true } },
    });

    const firstSnapshot = await snapshot(realm);
    expect(firstSnapshot.entries).toEqual([
      { log_id: LOG_ID, entry_id: ENTRY_1, bytes: Array.from(Uint8Array.from(atob(source.logs[0].entries[0]), (char) => char.charCodeAt(0))) },
      { log_id: LOG_ID, entry_id: ENTRY_2, bytes: Array.from(Uint8Array.from(atob(source.logs[0].entries[1]), (char) => char.charCodeAt(0))) },
    ]);
    expect(firstSnapshot.bundles).toEqual([{ bundle_id: source.bundle_id, state: "complete" }]);

    const inventory = await realmPost(realm, "/list-logs", { max_logs: 64 }, secret);
    expect(inventory.status).toBe(200);
    expect(inventory.json.ok).toBe(true);
    expect(inventory.json.result.logs).toHaveLength(1);

    const second = await realmPost(realm, "/restore-bundle-batch", source, secret);
    expect(second).toEqual({
      status: 200,
      json: { ok: true, result: { imported_logs: 0, skipped_logs: 1, complete: true } },
    });
    expect(await snapshot(realm)).toEqual(firstSnapshot);
  });

  it("refuses a public restore into a nonempty target without writing a bundle", async () => {
    const realm = realmName();
    const secret = await createRealm(realm);
    const created = await realmPost(realm, "/create-log", { log_id: UNRELATED_LOG_ID }, secret);
    expect(created).toEqual({ status: 201, json: { ok: true } });
    const before = await snapshot(realm);

    const refused = await realmPost(realm, "/restore-bundle-batch", bundle(), secret);
    expect(refused).toEqual({
      status: 409,
      json: { ok: false, error: { code: "constraint" } },
    });
    expect(await snapshot(realm)).toEqual(before);
  });
});
