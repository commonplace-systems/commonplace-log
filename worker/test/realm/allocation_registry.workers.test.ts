import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import {
  REALM_ALLOCATE_HEADER,
  REALM_ID_HEADER,
  RealmAuth,
  handlePublicRealmRequest,
} from "../../src/realm/realm_auth";
import type { RealmRegistry } from "../../src/realm/registry";
import { initRealmMetaSchema } from "../../src/realm/schema";

type Json = Record<string, unknown>;
type SnapshotValue = string | number | boolean | null | SnapshotValue[] | { [key: string]: SnapshotValue };
type Snapshot = Record<string, SnapshotValue[]>;

const DEPLOYMENT_TOKEN = "test-gateway-token";

function realmId(): string {
  return crypto.randomUUID();
}

function operationId(): string {
  return crypto.randomUUID();
}

function realmSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function normalize(value: unknown): SnapshotValue {
  if (value instanceof ArrayBuffer) return Array.from(new Uint8Array(value));
  if (ArrayBuffer.isView(value)) {
    return Array.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
  }
  if (Array.isArray(value)) return value.map(normalize);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value).map(([key, item]) => [key, normalize(item)]),
    ) as { [key: string]: SnapshotValue };
  }
  return value as SnapshotValue;
}

function snapshot(sql: SqlStorage): Snapshot {
  const tables = sql
    .exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    .toArray()
    .map((row) => String(row.name));
  return Object.fromEntries(tables.map((table) => {
    const quoted = `"${table.replaceAll('"', '""')}"`;
    return [table, sql.exec(`SELECT * FROM ${quoted}`).toArray().map(normalize)];
  })) as Snapshot;
}

type TestRegistry = RealmRegistry & {
  value: string | null;
  gets: number;
  puts: number;
  failPut: boolean;
};

function registry(initial: string | null = null): TestRegistry {
  return {
    value: initial,
    gets: 0,
    puts: 0,
    failPut: false,
    async get() {
      this.gets += 1;
      return this.value;
    },
    async put(realm, readCapability) {
      this.puts += 1;
      if (this.failPut) throw new Error("KV unavailable");
      this.value = JSON.stringify({ realm_id: realm, read_capability: readCapability, registered_at: "test" });
    },
    async delete() {
      this.value = null;
    },
  };
}

async function directAllocation(
  auth: RealmAuth,
  realm: string,
  operation: string,
  secret: string,
  suppliedRegistry: RealmRegistry | undefined,
  allowUnbound = false,
): Promise<{ status: number; json: Json }> {
  const response = await handlePublicRealmRequest(
    new Request("https://realm.invalid/realm/allocate", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        [REALM_ALLOCATE_HEADER]: "1",
        [REALM_ID_HEADER]: realm,
      },
      body: JSON.stringify({ operation_id: operation, realm_secret: secret }),
    }),
    auth,
    async () => Response.json({ ok: true, reached: true }),
    suppliedRegistry,
    allowUnbound,
  );
  return { status: response.status, json: await response.json() as Json };
}

async function withDirectRealm<T>(
  fn: (ctx: { auth: RealmAuth; sql: SqlStorage; realm: string }) => Promise<T>,
): Promise<T> {
  const realm = realmId();
  const stub = env.REALM_CONTAINER.getByName(realm);
  return await runInDurableObject(stub, async (_instance, state) => {
    initRealmMetaSchema(state.storage.sql);
    return await fn({
      auth: new RealmAuth(state.storage.sql, state.storage),
      sql: state.storage.sql,
      realm,
    });
  });
}

async function gatewayAllocation(
  realm: string,
  operation: string,
  secret: string,
  bearer: string | null = DEPLOYMENT_TOKEN,
): Promise<{ status: number; json: Json }> {
  const headers = new Headers({ "content-type": "application/json" });
  if (bearer !== null) headers.set("authorization", `Bearer ${bearer}`);
  const response = await SELF.fetch(`https://gateway.invalid/realms/${realm}/allocate`, {
    method: "POST",
    headers,
    body: JSON.stringify({ operation_id: operation, realm_secret: secret }),
  });
  return { status: response.status, json: await response.json() as Json };
}

async function realmSnapshot(realm: string): Promise<Snapshot> {
  return await runInDurableObject(env.REALM_CONTAINER.getByName(realm), (_instance, state) =>
    snapshot(state.storage.sql));
}

describe("deployed-base allocation and registry", () => {
  it("registers a usable capability, rejects stale registry data, and makes an exact retry KV-idempotent", async () => {
    await withDirectRealm(async ({ auth, sql, realm }) => {
      const stale = registry(JSON.stringify({ realm_id: realm, read_capability: "0".repeat(64) }));
      const operation = operationId();
      const secret = realmSecret();

      const refused = await directAllocation(auth, realm, operation, secret, stale);
      expect(refused).toEqual({
        status: 503,
        json: { ok: false, error: { code: "registry_registration_failed", details: { outcome: "registry_mismatch" } } },
      });
      expect(stale.puts).toBe(0);

      stale.value = null;
      const registered = await directAllocation(auth, realm, operation, secret, stale);
      expect(registered.status).toBe(200);
      expect(registered.json).toMatchObject({ ok: true, realm_id: realm, operation_id: operation, state: "allocated" });
      expect(registered.json).not.toHaveProperty("realm_secret");
      expect(stale.puts).toBe(1);
      const stored = JSON.parse(stale.value!) as Json;
      expect(stored.realm_id).toBe(realm);
      expect(stored.read_capability).toMatch(/^[0-9a-f]{64}$/);

      const read = String(stored.read_capability);
      const readResponse = await handlePublicRealmRequest(
        new Request("https://realm.invalid/frontier", { headers: { authorization: `Bearer ${read}` } }),
        auth,
        async () => Response.json({ ok: true, reached: true }),
        stale,
      );
      expect(readResponse.status).toBe(200);

      const beforeRetry = snapshot(sql);
      const retry = await directAllocation(auth, realm, operation, secret, stale);
      expect(retry.status).toBe(200);
      expect(retry.json).toEqual(registered.json);
      expect(stale.puts).toBe(1);
      expect(snapshot(sql)).toEqual(beforeRetry);
    });
  });

  it("refuses an unbound registry before SQL mutation even when the unsafe lever is supplied", async () => {
    await withDirectRealm(async ({ auth, sql, realm }) => {
      const before = snapshot(sql);
      const response = await directAllocation(auth, realm, operationId(), realmSecret(), undefined, true);
      expect(response).toEqual({
        status: 503,
        json: { ok: false, error: { code: "registry_not_bound", details: { binding: "REALM_REGISTRY" } } },
      });
      expect(snapshot(sql)).toEqual(before);
    });
  });

  it("names a KV write failure as pending work and recovers the same allocation on retry", async () => {
    await withDirectRealm(async ({ auth, sql, realm }) => {
      const failing = registry();
      failing.failPut = true;
      const operation = operationId();
      const secret = realmSecret();

      const failed = await directAllocation(auth, realm, operation, secret, failing);
      expect(failed).toEqual({
        status: 503,
        json: { ok: false, error: { code: "registry_registration_failed", details: { outcome: "registry_write_failed" } } },
      });
      expect(failing.puts).toBe(1);
      const pending = snapshot(sql);
      expect(pending).toHaveProperty("realm_allocations");
      expect(failing.value).toBeNull();

      failing.failPut = false;
      const recovered = await directAllocation(auth, realm, operation, secret, failing);
      expect(recovered.status).toBe(200);
      expect(recovered.json).toMatchObject({ ok: true, realm_id: realm, operation_id: operation, state: "allocated" });
      expect(failing.puts).toBe(2);
      expect(snapshot(sql)).toEqual(pending);
    });
  });

  it("does not restore a revoked read hash on an allocation retry", async () => {
    await withDirectRealm(async ({ auth, sql, realm }) => {
      const stored = registry();
      const operation = operationId();
      const secret = realmSecret();
      expect((await directAllocation(auth, realm, operation, secret, stored)).status).toBe(201);
      const registered = stored.value;
      auth.revokeReadCapability();
      const revoked = snapshot(sql);

      const retry = await directAllocation(auth, realm, operation, secret, stored);
      expect(retry).toEqual({ status: 409, json: { ok: false, error: { code: "allocation_conflict" } } });
      expect(stored.value).toBe(registered);
      expect(stored.puts).toBe(1);
      expect(snapshot(sql)).toEqual(revoked);
    });
  });

  it("requires the deployment bearer and never treats a read capability as allocation authority", async () => {
    const realm = realmId();
    const operation = operationId();
    const secret = realmSecret();
    const accepted = await gatewayAllocation(realm, operation, secret);
    expect(accepted.status).toBe(201);
    const registryValue = await env.REALM_REGISTRY.get<{ read_capability: string }>(realm, "json");
    expect(registryValue?.read_capability).toMatch(/^[0-9a-f]{64}$/);
    const before = await realmSnapshot(realm);
    const registryBefore = await env.REALM_REGISTRY.get(realm);

    expect((await gatewayAllocation(realm, operation, secret, null)).status).toBe(401);
    expect((await gatewayAllocation(realm, operation, secret, "wrong-deployment-token")).status).toBe(401);
    expect((await gatewayAllocation(realm, operation, secret, registryValue!.read_capability)).status).toBe(401);

    expect(await realmSnapshot(realm)).toEqual(before);
    expect(await env.REALM_REGISTRY.get(realm)).toBe(registryBefore);
  });
});
