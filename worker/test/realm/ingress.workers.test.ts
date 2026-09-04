import { SELF, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker, { handleIngress, type Env } from "../../src/index";
import type { RealmContainer } from "../../src/realm/container";

const DEPLOYMENT_TOKEN = "test-gateway-token";

function realmName(): string {
  return crypto.randomUUID();
}

function fetchGateway(path: string, init: RequestInit = {}, token: string | null = DEPLOYMENT_TOKEN) {
  const headers = new Headers(init.headers);
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return SELF.fetch(`https://gateway.invalid${path}`, { ...init, headers });
}

async function post(path: string, body: unknown, token: string | null) {
  const response = await fetchGateway(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }, token);
  return { status: response.status, json: await response.json() as Record<string, any> };
}

async function createRealm(realmId: string, locationHint?: string) {
  const body = locationHint === undefined ? {} : { location_hint: locationHint };
  return await post(`/realms/${realmId}`, body, DEPLOYMENT_TOKEN);
}

describe("realm ingress", () => {
  it("serves GET / unauthenticated", async () => {
    const response = await fetchGateway("/", {}, null);
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("commonplace-log");
  });

  it("creates once with and without a location hint and returns the secret only once", async () => {
    for (const hint of [undefined, "weur"]) {
      const realm = realmName();
      const created = await createRealm(realm, hint);
      expect(created).toEqual({
        status: 201,
        // ⭐ `registry` is ASSERTED, not tolerated. BACKUP-1b-i adds it to the create contract, and
        // an expectation edited merely to admit a new key would stop testing the body's shape --
        // the face-3 failure, where the check moves with the thing it checks. This edit ADDS a
        // claim: the gateway create path must report that the realm was registered.
        json: {
          ok: true,
          realm_id: realm,
          realm_secret: expect.stringMatching(/^[0-9a-f]{64}$/),
          registry: "registered",
        },
      });
      const second = await createRealm(realm);
      expect(second).toEqual({ status: 409, json: { ok: false, error: { code: "realm_exists" } } });
      expect(second.json).not.toHaveProperty("realm_secret");
    }
  });

  it("rejects invalid create bodies and location hints with 400", async () => {
    for (const body of [{ location_hint: "moon" }, { location_hint: 5 }, { extra: true }, []]) {
      expect(await post(`/realms/${realmName()}`, body, DEPLOYMENT_TOKEN)).toEqual({
        status: 400, json: { ok: false, error: { code: "malformed_request" } },
      });
    }
  });

  it("requires the deployment token for create", async () => {
    const realm = realmName();
    expect((await post(`/realms/${realm}`, {}, null)).status).toBe(401);
    expect((await post(`/realms/${realm}`, {}, "obvious-wrong-deployment-token")).status).toBe(401);
    expect((await createRealm(realm)).status).toBe(201);
  });

  it("returns not_found for sidecar, engine, and node paths of an uncreated realm", async () => {
    const realm = realmName();
    for (const path of ["/frontier", "/engine/ping", "/node/restart"]) {
      const response = await post(`/realms/${realm}${path}`, {}, "obvious-unassigned-realm-secret");
      expect(response, path).toEqual({ status: 404, json: { ok: false, error: { code: "not_found" } } });
    }
  });

  it("lets only the created realm's secret reach its routes", async () => {
    const realm = realmName();
    const created = await createRealm(realm);
    const secret = created.json.realm_secret as string;

    expect(await post(`/realms/${realm}/create-log`, { log_id: "log-x" }, "obvious-wrong-realm-secret"))
      .toEqual({ status: 401, json: { ok: false, error: { code: "unauthorized" } } });
    expect(await post(`/realms/${realm}/create-log`, { log_id: "log-x" }, DEPLOYMENT_TOKEN))
      .toEqual({ status: 401, json: { ok: false, error: { code: "unauthorized" } } });
    expect(await post(`/realms/${realm}/create-log`, { log_id: "log-x" }, secret))
      .toEqual({ status: 201, json: { ok: true } });
    expect(await post(`/realms/${realm}/frontier`, { log_id: "log-x" }, secret))
      .toEqual({ status: 200, json: { ok: true, frontier: { writers: [] } } });
    expect(await post(`/realms/${realm}/realm/create`, {}, secret))
      .toEqual({ status: 404, json: { ok: false, error: { code: "not_found" } } });
  });

  it("keeps two realm secrets scoped, with positive controls both ways", async () => {
    const realmA = realmName();
    const realmB = realmName();
    const secretA = (await createRealm(realmA)).json.realm_secret as string;
    const secretB = (await createRealm(realmB)).json.realm_secret as string;

    expect((await post(`/realms/${realmA}/create-log`, { log_id: "a" }, secretB)).status).toBe(401);
    expect((await post(`/realms/${realmB}/create-log`, { log_id: "b" }, secretA)).status).toBe(401);
    expect((await post(`/realms/${realmA}/create-log`, { log_id: "a" }, secretA)).status).toBe(201);
    expect((await post(`/realms/${realmB}/create-log`, { log_id: "b" }, secretB)).status).toBe(201);
    expect((await post(`/realms/${realmA}/frontier`, { log_id: "a" }, secretA)).status).toBe(200);
    expect((await post(`/realms/${realmB}/frontier`, { log_id: "b" }, secretB)).status).toBe(200);
  });

  it("requires a syntactically valid bearer on realm routes", async () => {
    const realm = realmName();
    const missing = await fetchGateway(`/realms/${realm}/frontier`, { method: "POST", body: "{}" }, null);
    expect(missing.status).toBe(401);
    expect(await missing.json()).toEqual({ ok: false, error: { code: "unauthorized" } });
    expect((await SELF.fetch(`https://gateway.invalid/realms/${realm}/frontier`, {
      method: "POST", body: "{}", headers: { authorization: "Basic obvious-fake" },
    })).status).toBe(401);
  });

  it("returns 404 for malformed realm ids and unknown top-level paths", async () => {
    const uuid = "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee";
    for (const path of [
      "/realms/", "/realms", "/realms//commit", "/realms/bad%20id/commit", "/realms/a:b/commit",
      `/realms/${"x".repeat(129)}/commit`, "/realms/../commit", `/realms/${uuid.toUpperCase()}/commit`,
      "/realms/acme-1/commit", `/realms/${uuid}-trailing/commit`,
    ]) {
      const response = await fetchGateway(path, { method: "POST", body: "{}" });
      expect(response.status, path).toBe(404);
      expect(await response.json()).toEqual({ ok: false, error: { code: "not_found" } });
    }
    expect((await fetchGateway("/health")).status).toBe(404);
    expect((await fetchGateway("/", { method: "POST" })).status).toBe(404);
  });

  it("needs GATEWAY_TOKEN only for create, not for an authorized realm route", async () => {
    const realm = realmName();
    const secret = (await createRealm(realm)).json.realm_secret as string;
    const fakeEnv: Env = { REALM_CONTAINER: env.REALM_CONTAINER, GATEWAY_TOKEN: undefined };
    const create = new Request(`https://gateway.invalid/realms/${realmName()}`, {
      method: "POST", headers: { authorization: `Bearer ${DEPLOYMENT_TOKEN}` }, body: "{}",
    });
    const createResponse = await handleIngress(create, fakeEnv);
    expect(createResponse.status).toBe(503);
    await createResponse.json();

    const realmRequest = new Request(`https://gateway.invalid/realms/${realm}/create-log`, {
      method: "POST",
      headers: { authorization: `Bearer ${secret}`, "content-type": "application/json" },
      body: JSON.stringify({ log_id: "still-open" }),
    });
    const realmResponse = await handleIngress(realmRequest, fakeEnv);
    expect(realmResponse.status).toBe(201);
    await realmResponse.json();
    const liveness = await worker.fetch(new Request("https://gateway.invalid/"), fakeEnv);
    expect(liveness.status).toBe(200);
    await liveness.text();
  });

  it("passes a validated location hint to idFromName plus get for create", async () => {
    const calls: Array<{ id: unknown; options: unknown }> = [];
    const namespace = {
      idFromName(name: string) { return { name }; },
      get(id: unknown, options?: unknown) {
        calls.push({ id, options });
        return { fetch: async () => Response.json({ ok: true }, { status: 201 }) };
      },
    } as unknown as DurableObjectNamespace<RealmContainer>;
    const realm = realmName();
    const request = new Request(`https://gateway.invalid/realms/${realm}`, {
      method: "POST",
      headers: { authorization: `Bearer ${DEPLOYMENT_TOKEN}`, "content-type": "application/json" },
      body: JSON.stringify({ location_hint: "weur" }),
    });
    const response = await handleIngress(request, { REALM_CONTAINER: namespace, GATEWAY_TOKEN: DEPLOYMENT_TOKEN });
    expect(response.status).toBe(201);
    expect(calls).toEqual([{ id: { name: realm }, options: { locationHint: "weur" } }]);
  });
});
