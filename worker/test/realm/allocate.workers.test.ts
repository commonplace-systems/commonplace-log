import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";

/**
 * Focused contract for the caller-owned deployment allocation primitive.
 * The caller saves the 64-character secret before this request; the provider
 * stores only its hash. These tests use real SELF ingress and the real
 * RealmContainer SQLite storage, never a storageFetch shim.
 */
type Json = Record<string, any>;
type SqlValue = string | number | boolean | null | SqlValue[] | { [key: string]: SqlValue };
type SqlRow = Record<string, SqlValue>;
type Snapshot = Record<string, SqlRow[]>;

const DEPLOYMENT_TOKEN = "test-gateway-token";
const REALM_SECRET_BYTES = 32;

function realmName(): string {
  return crypto.randomUUID();
}

function operationId(): string {
  return crypto.randomUUID();
}

function realmSecret(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(REALM_SECRET_BYTES));
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function gatewayFetch(path: string, init: RequestInit = {}, token: string | null = DEPLOYMENT_TOKEN) {
  const headers = new Headers(init.headers);
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return SELF.fetch(`https://gateway.invalid${path}`, { ...init, headers });
}

async function allocate(
  realmId: string,
  body: { operation_id: string; realm_secret: string; location_hint?: string },
  token: string | null = DEPLOYMENT_TOKEN,
): Promise<{ status: number; json: Json }> {
  const response = await gatewayFetch(`/realms/${realmId}/allocate`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }, token);
  return { status: response.status, json: await response.json() as Json };
}

function normalize(value: unknown): SqlValue {
  if (value instanceof ArrayBuffer) return Array.from(new Uint8Array(value));
  if (ArrayBuffer.isView(value)) return Array.from(new Uint8Array(value.buffer, value.byteOffset, value.byteLength));
  if (Array.isArray(value)) return value.map(normalize);
  if (value !== null && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [key, normalize(item)])) as { [key: string]: SqlValue };
  }
  return value as SqlValue;
}

async function snapshot(realmId: string): Promise<Snapshot> {
  const target = env.REALM_CONTAINER.getByName(realmId);
  return await runInDurableObject(target, (_instance, state) => {
    const tables = state.storage.sql
      .exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
      .toArray()
      .map((row) => String(row.name));

    return Object.fromEntries(tables.map((table) => {
      const quoted = `"${table.replaceAll('"', '""')}"`;
      const rows = state.storage.sql.exec(`SELECT * FROM ${quoted}`).toArray();
      return [table, rows.map((row) => Object.fromEntries(
        Object.entries(row).map(([key, value]) => [key, normalize(value)]),
      ))];
    })) as Snapshot;
  });
}

function expectAccepted(response: { status: number; json: Json }, realmId: string, op: string) {
  expect(response.status).toBe(201);
  expect(response.json.ok).toBe(true);
  expect(response.json.realm_id).toBe(realmId);
  expect(response.json.operation_id).toBe(op);
  expect(response.json.state).toBe("allocated");
  expect(response.json).not.toHaveProperty("realm_secret");
}

function expectUnauthorized(response: { status: number; json: Json }) {
  expect(response).toEqual({ status: 401, json: { ok: false, error: { code: "unauthorized" } } });
}

function expectConflict(response: { status: number; json: Json }) {
  expect(response).toEqual({
    status: 409,
    json: { ok: false, error: { code: "allocation_conflict" } },
  });
}

describe("deployment allocation ingress", () => {
  it("acknowledges the first allocation and returns the exact result on an idempotent retry", async () => {
    const realm = realmName();
    const operation = operationId();
    const secret = realmSecret();
    const request = { operation_id: operation, realm_secret: secret };

    const first = await allocate(realm, request);
    expectAccepted(first, realm, operation);
    const acknowledged = JSON.parse(JSON.stringify(first.json)) as Json;
    const beforeRetry = await snapshot(realm);

    const retry = await allocate(realm, request);
    expect(retry.status).toBe(200);
    expect(retry.json).toEqual(acknowledged);
    expect(retry.json).not.toHaveProperty("realm_secret");
    expect(await snapshot(realm)).toEqual(beforeRetry);
  });

  it("refuses a different operation and a conflicting secret without changing the allocation", async () => {
    const realm = realmName();
    const operation = operationId();
    const secret = realmSecret();
    const request = { operation_id: operation, realm_secret: secret };
    expectAccepted(await allocate(realm, request), realm, operation);
    const before = await snapshot(realm);

    const differentOperation = await allocate(realm, { operation_id: operationId(), realm_secret: secret });
    expectConflict(differentOperation);
    expect(await snapshot(realm)).toEqual(before);

    const conflictingSecret = await allocate(realm, { operation_id: operation, realm_secret: realmSecret() });
    expectConflict(conflictingSecret);
    expect(await snapshot(realm)).toEqual(before);
  });

  it("refuses allocation into a realm created through the legacy create route", async () => {
    const realm = realmName();
    const created = await gatewayFetch(`/realms/${realm}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: "{}",
    });
    expect(created.status).toBe(201);
    const before = await snapshot(realm);

    const response = await allocate(realm, { operation_id: operationId(), realm_secret: realmSecret() });
    expectConflict(response);
    expect(await snapshot(realm)).toEqual(before);
  });

  it("rejects missing, wrong, and realm-secret bearer authorization before allocation", async () => {
    const realm = realmName();
    const request = { operation_id: operationId(), realm_secret: realmSecret() };
    const before = await snapshot(realm);

    expectUnauthorized(await allocate(realm, request, null));
    expect(await snapshot(realm)).toEqual(before);
    expectUnauthorized(await allocate(realm, request, "obvious-wrong-deployment-token"));
    expect(await snapshot(realm)).toEqual(before);
    expectUnauthorized(await allocate(realm, request, request.realm_secret));
    expect(await snapshot(realm)).toEqual(before);
  });

  it("refuses an internal allocation path and spoof markers for wrong and realm bearers", async () => {
    const realm = realmName();
    const request = { operation_id: operationId(), realm_secret: realmSecret() };
    expectAccepted(await allocate(realm, request), realm, request.operation_id);
    const before = await snapshot(realm);
    const headers = {
      "content-type": "application/json",
      "x-commonplace-realm-allocate": "1",
      "x-commonplace-realm-id": realm,
    };

    const wrong = await gatewayFetch(`/realms/${realm}/realm/allocate`, {
      method: "POST",
      headers,
      body: JSON.stringify(request),
    }, "obvious-wrong-realm-secret");
    expect(wrong.status).toBe(404);
    expect(await wrong.json()).toEqual({ ok: false, error: { code: "not_found" } });

    const realmBearer = await gatewayFetch(`/realms/${realm}/realm/allocate`, {
      method: "POST",
      headers,
      body: JSON.stringify(request),
    }, request.realm_secret);
    expect(realmBearer.status).toBe(404);
    expect(await realmBearer.json()).toEqual({ ok: false, error: { code: "not_found" } });
    expect(await snapshot(realm)).toEqual(before);
  });

  it("authenticates the supplied secret and never persists its plaintext", async () => {
    const realm = realmName();
    const secret = realmSecret();
    const operation = operationId();
    const response = await allocate(realm, { operation_id: operation, realm_secret: secret, location_hint: "weur" });
    expectAccepted(response, realm, operation);

    const inventory = await gatewayFetch(`/realms/${realm}/list-logs`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ max_logs: 64 }),
    }, secret);
    expect(inventory.status).toBe(200);
    const inventoryJson = await inventory.json() as Json;
    expect(inventoryJson.ok).toBe(true);
    expect(inventoryJson.result.logs).toEqual([]);

    const stored = JSON.stringify(await snapshot(realm));
    expect(stored).not.toContain(secret);
    expect(response.json).not.toHaveProperty("realm_secret");
  });

  it("rejects malformed secret material instead of treating a non-hex value as an allocation credential", async () => {
    const realm = realmName();
    const before = await snapshot(realm);
    const response = await allocate(realm, { operation_id: operationId(), realm_secret: "not-a-lowercase-hex-secret" });
    expect(response.status).toBe(400);
    expect(response.json).toEqual({ ok: false, error: { code: "malformed_request" } });
    expect(await snapshot(realm)).toEqual(before);
  });
});
