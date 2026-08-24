import { SELF, env } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker, { handleIngress, type Env } from "../../src/index";

const TOKEN = "test-gateway-token";
let realmSequence = 0;

function realmName(): string {
  return `ingress-${Date.now()}-${realmSequence++}`;
}

function fetchGateway(path: string, init: RequestInit = {}, token: string | null = TOKEN) {
  const headers = new Headers(init.headers);
  if (token !== null) headers.set("authorization", `Bearer ${token}`);
  return SELF.fetch(`https://gateway.invalid${path}`, { ...init, headers });
}

async function post(path: string, body: unknown, token: string | null = TOKEN) {
  const response = await fetchGateway(path, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }, token);
  return { status: response.status, json: await response.json() as Record<string, any> };
}

function entry(entryId: string, writerId: string, writerSeq: number, prevEntryId: string | null) {
  const createdAt = "2026-08-24T00:00:00Z";
  const fields = { entry_id: entryId, writer_id: writerId, writer_seq: writerSeq, prev_entry_id: prevEntryId, created_at: createdAt };
  return { ...fields, canonical_bytes: btoa(JSON.stringify(fields)) };
}

describe("realm ingress", () => {
  it("serves GET / unauthenticated", async () => {
    const response = await fetchGateway("/", {}, null);
    expect(response.status).toBe(200);
    expect(await response.text()).toBe("commonplace-log");
  });

  it("rejects a missing bearer token with 401 and never echoes the token", async () => {
    const response = await fetchGateway(`/realms/${realmName()}/frontier`, { method: "POST", body: "{}" }, null);
    expect(response.status).toBe(401);
    expect(await response.json()).toEqual({ ok: false, error: { code: "unauthorized" } });
  });

  it("rejects a wrong bearer token with 401 and never echoes the token", async () => {
    const wrong = "wrong-gateway-token-value";
    const response = await fetchGateway(`/realms/${realmName()}/frontier`, { method: "POST", body: "{}" }, wrong);
    expect(response.status).toBe(401);
    const text = await response.text();
    expect(JSON.parse(text)).toEqual({ ok: false, error: { code: "unauthorized" } });
    expect(text).not.toContain(wrong);
    expect(text).not.toContain(TOKEN);
    // Same-length wrong token exercises the constant-time branch, not the length guard.
    const sameLength = TOKEN.replace(/./g, "x");
    expect((await fetchGateway("/realms/r/frontier", { method: "POST", body: "{}" }, sameLength)).status).toBe(401);
    // A non-Bearer scheme is not a token.
    expect((await SELF.fetch("https://gateway.invalid/realms/r/frontier", {
      method: "POST", body: "{}", headers: { authorization: `Basic ${TOKEN}` },
    })).status).toBe(401);
  });

  it("proxies an authenticated request to the realm sidecar, path and body intact", async () => {
    const realm = realmName();
    const created = await post(`/realms/${realm}/create-log`, { log_id: "log-x", format_version: 1 });
    expect(created).toEqual({ status: 201, json: { ok: true } });
    // The sidecar's own error envelope comes back through unchanged.
    expect(await post(`/realms/${realm}/no-such-sidecar-route`, {})).toEqual({
      status: 404, json: { ok: false, error: { code: "not_found" } },
    });
    expect(await post(`/realms/${realm}/create-log`, { log_id: 5 })).toEqual({
      status: 400, json: { ok: false, error: { code: "malformed_request" } },
    });
  });

  it("path-derived realm isolation: a log committed in realm A is absent from realm B", async () => {
    const realmA = realmName();
    const realmB = realmName();
    expect((await post(`/realms/${realmA}/create-log`, { log_id: "shared-name", format_version: 1 })).status).toBe(201);
    const first = entry("e1", "alice", 1, null);
    const commit = await post(`/realms/${realmA}/commit`, {
      log_id: "shared-name", expected_revision: 0, expected_epoch: 0,
      insert_entries: [first],
      put_tips: [{ writer_id: "alice", last_seq: 1, last_entry_id: "e1" }],
    });
    expect(commit).toEqual({ status: 200, json: { ok: true, revision: 1 } });

    expect(await post(`/realms/${realmA}/frontier`, { log_id: "shared-name" })).toEqual({
      status: 200,
      json: { ok: true, frontier: { writers: [{ writer_id: "alice", seq: 1, entry_id: "e1" }] } },
    });
    expect(await post(`/realms/${realmB}/frontier`, { log_id: "shared-name" })).toEqual({
      status: 404, json: { ok: false, error: { code: "not_found" } },
    });
    // Positive control for the instrument: realm B does hold its own logs.
    expect((await post(`/realms/${realmB}/create-log`, { log_id: "only-in-b", format_version: 1 })).status).toBe(201);
    expect((await post(`/realms/${realmB}/frontier`, { log_id: "only-in-b" })).json).toEqual({
      ok: true, frontier: { writers: [] },
    });
    expect((await post(`/realms/${realmA}/frontier`, { log_id: "only-in-b" })).status).toBe(404);
  });

  it("returns 404 for malformed realm ids and unknown top-level paths", async () => {
    for (const path of [
      "/realms/", "/realms", "/realms//commit", "/realms/bad%20id/commit", "/realms/a:b/commit",
      `/realms/${"x".repeat(129)}/commit`, "/realms/../commit",
    ]) {
      const response = await fetchGateway(path, { method: "POST", body: "{}" });
      expect(response.status, path).toBe(404);
      expect(await response.json()).toEqual({ ok: false, error: { code: "not_found" } });
    }
    expect((await fetchGateway("/realm/a/commit", { method: "POST", body: "{}" })).status).toBe(404);
    expect((await fetchGateway("/health")).status).toBe(404);
    expect((await fetchGateway("/", { method: "POST" })).status).toBe(404);
  });

  it("fails closed with 503 for every request when GATEWAY_TOKEN is unset or empty", async () => {
    for (const token of [undefined, ""]) {
      const fakeEnv: Env = { REALM_CONTAINER: env.REALM_CONTAINER, GATEWAY_TOKEN: token };
      const withGoodToken = new Request("https://gateway.invalid/realms/r/frontier", {
        method: "POST", body: "{}", headers: { authorization: `Bearer ${TOKEN}` },
      });
      const response = await handleIngress(withGoodToken, fakeEnv);
      expect(response.status).toBe(503);
      expect(await response.json()).toEqual({ ok: false, error: { code: "gateway_not_configured" } });
      expect((await worker.fetch(new Request("https://gateway.invalid/health"), fakeEnv)).status).toBe(503);
      // Liveness stays up; it is the only route that never consults the token.
      expect((await handleIngress(new Request("https://gateway.invalid/"), fakeEnv)).status).toBe(200);
    }
    // Control: the same handler, given the configured token, gets past the 503 gate.
    const configured: Env = { REALM_CONTAINER: env.REALM_CONTAINER, GATEWAY_TOKEN: TOKEN };
    expect((await handleIngress(new Request("https://gateway.invalid/health"), configured)).status).toBe(401);
    expect((await handleIngress(new Request("https://gateway.invalid/health", {
      headers: { authorization: `Bearer ${TOKEN}` },
    }), configured)).status).toBe(404);
  });
});
