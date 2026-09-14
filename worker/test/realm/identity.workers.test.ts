import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import {
  REALM_ALLOCATE_HEADER,
  REALM_CREATE_HEADER,
  REALM_ID_HEADER,
  RealmAuth,
  handlePublicRealmRequest,
} from "../../src/realm/realm_auth";
import { initRealmMetaSchema } from "../../src/realm/schema";
import type { RealmRegistry } from "../../src/realm/registry";

/**
 * REALM-IDENTITY-1: the realm surface's §13.1 analogue. Every lifecycle request
 * carries the gateway-set x-commonplace-realm-id header; when the Durable Object
 * was addressed by name (ctx.id.name is a string), the header must equal that
 * name, or a gateway routing bug would create/serve/delete under a mismatched
 * identity — and reconciliation would later delete the registry row pointing at
 * the real data. When ctx.id.name is undefined (always the case under
 * vitest-pool-workers — the SP2 finding) the comparison is skipped, and requests
 * that carry no realm-id header (every ordinary app route) are never affected.
 *
 * These arms call handlePublicRealmRequest DIRECTLY with an injected objectName,
 * exactly the way test/do/http.test.ts injects deps.objectName: the pool cannot
 * make ctx.id.name a string, so the real DO lane can never present a mismatch
 * here. The wiring from ctx.id.name to the argument is therefore asserted as a
 * SOURCE FACT below (the R6 pattern from read_capability.workers.test.ts),
 * labelled as one.
 */

type Json = Record<string, unknown>;

let sequence = 0;

function fakeRegistry(): RealmRegistry {
  let value: string | null = null;
  return {
    async get() { return value; },
    async put(realm, readCapability) {
      value = JSON.stringify({ realm_id: realm, read_capability: readCapability, registered_at: "test" });
    },
    async delete() { value = null; },
  };
}

async function withRealmState<T>(
  fn: (ctx: { auth: RealmAuth; realm: string; wipe: () => Promise<void> }) => Promise<T>,
): Promise<T> {
  const realm = `identity-${Date.now()}-${sequence++}`;
  const stub = env.REALM_CONTAINER.getByName(realm);
  return await runInDurableObject(stub, async (_instance, state) => {
    initRealmMetaSchema(state.storage.sql);
    return await fn({
      auth: new RealmAuth(state.storage.sql, state.storage),
      realm,
      wipe: () => state.storage.deleteAll(),
    });
  });
}

function call(
  auth: RealmAuth,
  objectName: string | undefined,
  path: string,
  headers: Record<string, string>,
  options: { method?: string; body?: unknown; registry?: RealmRegistry; wipe?: () => Promise<void> } = {},
): Promise<Response> {
  return handlePublicRealmRequest(
    new Request(`https://realm.invalid${path}`, {
      method: options.method ?? "POST",
      headers: { "content-type": "application/json", ...headers },
      body: options.body === undefined ? undefined : JSON.stringify(options.body),
    }),
    auth,
    async () => Response.json({ ok: true, reached: true }),
    options.registry,
    options.registry === undefined, // unbound fixtures ask for the unbound behaviour by name
    options.wipe,
    objectName,
  );
}

const wrongRealmEnvelope = (objectName: string, realmId: string) => ({
  ok: false,
  error: { code: "wrong_realm", details: { object_name: objectName, realm_id: realmId } },
});

describe("REALM-IDENTITY-1: lifecycle realm-id header vs ctx.id.name", () => {
  it("create: mismatched header is refused with wrong_realm and creates nothing; the matching neighbour then succeeds", async () => {
    await withRealmState(async ({ auth, realm }) => {
      const refused = await call(auth, realm, "/realm/create", {
        [REALM_CREATE_HEADER]: "1",
        [REALM_ID_HEADER]: `${realm}-other`,
      });
      expect(refused.status).toBe(409);
      expect(await refused.json()).toEqual(wrongRealmEnvelope(realm, `${realm}-other`));

      // ⭐ VALID NEIGHBOUR + side-effect control in one: the SAME request with the
      // MATCHING header gets 201, which it could not if the refusal had created
      // the realm on the way out (that would be realm_exists 409).
      const created = await call(auth, realm, "/realm/create", {
        [REALM_CREATE_HEADER]: "1",
        [REALM_ID_HEADER]: realm,
      });
      expect(created.status).toBe(201);
      const body = await created.json<Json>();
      expect(body.ok).toBe(true);
      expect(body.realm_id).toBe(realm);
      console.info("IDENTITY create mismatch=%d matching neighbour=%d", refused.status, created.status);
    });
  });

  it("allocate: mismatched header is refused before touching auth or registry; the matching neighbour allocates", async () => {
    await withRealmState(async ({ auth, realm }) => {
      const registry = fakeRegistry();
      const allocation = { operation_id: "op-1", realm_secret: "a".repeat(64) };
      const refused = await call(auth, realm, "/realm/allocate", {
        [REALM_ALLOCATE_HEADER]: "1",
        [REALM_ID_HEADER]: `${realm}-other`,
      }, { body: allocation, registry });
      expect(refused.status).toBe(409);
      expect(await refused.json()).toEqual(wrongRealmEnvelope(realm, `${realm}-other`));

      const allocated = await call(auth, realm, "/realm/allocate", {
        [REALM_ALLOCATE_HEADER]: "1",
        [REALM_ID_HEADER]: realm,
      }, { body: allocation, registry });
      expect(allocated.status).toBe(201);
      expect(await allocated.json()).toEqual({
        ok: true, realm_id: realm, operation_id: "op-1", state: "allocated",
      });
      console.info("IDENTITY allocate mismatch=%d matching neighbour=%d", refused.status, allocated.status);
    });
  });

  it("removal: mismatched header is refused with the realm intact; the matching neighbour removes", async () => {
    await withRealmState(async ({ auth, realm, wipe }) => {
      const created = await call(auth, realm, "/realm/create", {
        [REALM_CREATE_HEADER]: "1",
        [REALM_ID_HEADER]: realm,
      });
      expect(created.status).toBe(201);
      const { realm_secret: write } = await created.json<{ realm_secret: string }>();

      const refused = await call(auth, realm, "/", {
        authorization: `Bearer ${write}`,
        [REALM_ID_HEADER]: `${realm}-other`,
      }, { method: "DELETE", wipe });
      expect(refused.status).toBe(409);
      expect(await refused.json()).toEqual(wrongRealmEnvelope(realm, `${realm}-other`));

      // The realm survived the refusal: its own secret still authorizes.
      const alive = await call(auth, realm, "/frontier", { authorization: `Bearer ${write}` });
      expect(alive.status).toBe(200);
      expect(await alive.json()).toEqual({ ok: true, reached: true });

      const removed = await call(auth, realm, "/", {
        authorization: `Bearer ${write}`,
        [REALM_ID_HEADER]: realm,
      }, { method: "DELETE", wipe });
      expect(removed.status).toBe(204);
      console.info("IDENTITY removal mismatch=%d survivor frontier=%d matching neighbour=%d", refused.status, alive.status, removed.status);
    });
  });

  it("undefined ctx.id.name (the vitest-pool-workers state) skips the comparison, exactly the tolerance do/ tests rely on", async () => {
    await withRealmState(async ({ auth, realm }) => {
      // Any header value at all: with no name there is nothing to verify against.
      const created = await call(auth, undefined, "/realm/create", {
        [REALM_CREATE_HEADER]: "1",
        [REALM_ID_HEADER]: `${realm}-not-the-object-name`,
      });
      expect(created.status).toBe(201);
      console.info("IDENTITY undefined-name create=%d (comparison skipped)", created.status);
    });
  });

  it("ordinary routes carry no realm-id header and are never touched by the check", async () => {
    await withRealmState(async ({ auth, realm }) => {
      const created = await call(auth, realm, "/realm/create", {
        [REALM_CREATE_HEADER]: "1",
        [REALM_ID_HEADER]: realm,
      });
      expect(created.status).toBe(201);
      const { realm_secret: write } = await created.json<{ realm_secret: string }>();

      // No realm-id header, objectName present: the app's shape today. Must reach
      // the authorized handler untouched.
      const frontier = await call(auth, realm, "/frontier", { authorization: `Bearer ${write}` });
      expect(frontier.status).toBe(200);
      expect(await frontier.json()).toEqual({ ok: true, reached: true });
      console.info("IDENTITY headerless ordinary route=%d (check ignored it)", frontier.status);
    });
  });
});

import nodeSource from "../../src/realm/node.ts?raw";
import containerSource from "../../src/realm/container.ts?raw";

describe("REALM-IDENTITY-1 wiring: both lanes hand ctx.id.name to the choke point", () => {
  /**
   * SOURCE FACT, labelled as one (the R6 pattern and its reason): the arms above
   * prove handlePublicRealmRequest refuses when objectName is a string, but under
   * vitest-pool-workers ctx.id.name is ALWAYS undefined, so no executed lane arm
   * can show a real DO presenting a name. What can be shown is that each lane's
   * single fetch entry passes `this.ctx.id.name` into the call the R6 gate
   * already proves it delegates to.
   */
  const lanes: ReadonlyArray<[string, string]> = [
    ["realm/node.ts", nodeSource],
    ["realm/container.ts", containerSource],
  ];

  function fetchCallRegion(source: string): string {
    const body = source.slice(source.indexOf("override async fetch("));
    return body.slice(0, body.indexOf("\n  }"));
  }

  it("each lane's fetch passes this.ctx.id.name into handlePublicRealmRequest", () => {
    for (const [name, source] of lanes) {
      const region = fetchCallRegion(source);
      expect([name, region.includes("handlePublicRealmRequest(request, this.auth")]).toEqual([name, true]);
      expect([name, region.includes("this.ctx.id.name")]).toEqual([name, true]);
    }
  });

  it("CONTROL: the recogniser can fail - a lane that omits the identity argument is rejected", () => {
    const bypassing = `export class Fake {\n  override async fetch(request: Request) {\n    return await handlePublicRealmRequest(request, this.auth, authorized);\n  }\n}`;
    const region = fetchCallRegion(bypassing);
    expect(region.includes("handlePublicRealmRequest(request, this.auth")).toBe(true);
    expect(region.includes("this.ctx.id.name")).toBe(false);
  });
});
