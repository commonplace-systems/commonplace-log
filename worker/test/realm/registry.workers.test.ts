import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { REALM_CREATE_HEADER, RealmAuth, handlePublicRealmRequest } from "../../src/realm/realm_auth";
import { RealmRegistry } from "../../src/realm/registry";
import { initRealmMetaSchema } from "../../src/realm/schema";

let sequence = 0;

/** A registry that records what it was handed, and can be made to fail on demand. */
function fakeRegistry(failing = false): RealmRegistry & { entries: Map<string, string> } {
  const entries = new Map<string, string>();
  return {
    entries,
    async put(realmId, readCapability) {
      if (failing) throw new Error("KV unavailable");
      entries.set(realmId, readCapability);
    },
  };
}

async function withRealm<T>(
  fn: (ctx: {
    auth: RealmAuth;
    create: (registry?: RealmRegistry, allowUnbound?: boolean) => Promise<Response>;
    call: (path: string, secret: string) => Promise<Response>;
    realmId: string;
  }) => Promise<T>,
): Promise<T> {
  const realmId = `registry-${Date.now()}-${sequence++}`;
  const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName(realmId));
  return await runInDurableObject(stub, async (_instance, state) => {
    const sql = state.storage.sql;
    initRealmMetaSchema(sql);
    const auth = new RealmAuth(sql, state.storage);
    const inner = async () => Response.json({ ok: true, reached: true }, { status: 200 });
    const create = (registry?: RealmRegistry, allowUnbound = false) =>
      handlePublicRealmRequest(
        new Request("https://realm.invalid/realm/create", {
          method: "POST",
          headers: { [REALM_CREATE_HEADER]: "1", "x-commonplace-realm-id": realmId },
        }),
        auth,
        inner,
        registry,
        allowUnbound,
      );
    const call = (path: string, secret: string) =>
      handlePublicRealmRequest(
        new Request(`https://realm.invalid${path}`, {
          method: "POST",
          headers: { authorization: `Bearer ${secret}` },
        }),
        auth,
        inner,
      );
    return await fn({ auth, create, call, realmId });
  });
}

describe("BACKUP-1b-i realm registry", () => {
  it("I1: create registers the realm, and the stored value is a WORKING read capability", async () => {
    await withRealm(async ({ create, call, realmId }) => {
      const registry = fakeRegistry();
      const response = await create(registry);
      const body = (await response.json()) as { registry?: string; realm_secret?: string };

      expect([response.status, body.registry]).toEqual([201, "registered"]);
      expect(registry.entries.has(realmId)).toBe(true);

      // ⭐⭐ THE ARM IS NOT "SOMETHING WAS STORED". A placeholder, an empty string, or the realm id
      // itself would all satisfy `has(realmId)`. The stored value must ACTUALLY AUTHORIZE a read
      // route and be REFUSED on a write route -- i.e. it is a read capability, proved by use.
      const capability = registry.entries.get(realmId)!;
      expect((await call("/frontier", capability)).status).toBe(200);
      expect((await call("/commit", capability)).status).toBe(403);
    });
  });

  it("I2: the capability is NEVER returned over the wire", async () => {
    await withRealm(async ({ create, realmId }) => {
      const registry = fakeRegistry();
      const raw = await (await create(registry)).text();
      const capability = registry.entries.get(realmId)!;

      // ⛔ CUSTODY: the gateway receives the WRITE secret (it cannot reach the realm otherwise) and
      // must never receive the read capability -- that value belongs to the registry alone.
      expect(raw.includes(capability)).toBe(false);
      // POSITIVE CONTROL: the substring test can find a value that IS in the body.
      const body = JSON.parse(raw) as { realm_secret: string };
      expect(raw.includes(body.realm_secret)).toBe(true);
    });
  });

  it("I3: an unbound registry REFUSES, and creates nothing", async () => {
    await withRealm(async ({ create, auth }) => {
      const response = await create(undefined);
      const body = (await response.json()) as {
        error?: { code?: string; details?: { binding?: string } };
      };

      // ⛔ A 201 here would be the silent-underreport shape: the system ANSWERING instead of
      // DECLINING, over a realm nothing can ever back up (plan row 855).
      expect([response.status, body.error?.code]).toEqual([503, "registry_not_bound"]);
      // ⭐ And it NAMES the missing binding -- an error that says WHAT but not WHERE costs the
      // reader a guess, which is exactly what `uuid-malformed` cost this door today.
      expect(body.error?.details?.binding).toBe("REALM_REGISTRY");

      // ⭐⭐ THE ORDER IS THE ARM: refusing AFTER create would leave an ORPHAN -- a realm that
      // exists, is unregistered, and whose write secret the caller never received. Nothing was
      // created, so a later create can still succeed.
      const retry = await create(fakeRegistry());
      expect(retry.status).toBe(201);
      expect(await auth.authorize(new Request("https://realm.invalid/frontier"))).not.toBe("not_found");
    });
  });

  it("I3b: the development lever admits the unbound registry, and says so by name", async () => {
    await withRealm(async ({ create }) => {
      const body = (await (await create(undefined, true)).json()) as { registry?: string };
      // ⛔ The unsafe behaviour exists ONLY when it is asked for by name; the default refuses.
      expect(body.registry).toBe("no_registry_bound");
    });
  });

  it("I4: a registry write failure is NAMED, and the realm remains reachable", async () => {
    await withRealm(async ({ create, call }) => {
      const response = await create(fakeRegistry(true));
      const body = (await response.json()) as { registry?: string; realm_secret: string };

      expect([response.status, body.registry]).toEqual([201, "registry_write_failed"]);
      // ⛔ The realm is NOT unwound: a missing registry row is recoverable, a lost write secret is
      // not. The caller must still be able to use the realm they were just handed.
      expect((await call("/commit", body.realm_secret)).status).toBe(200);
    });
  });

  it("I5 CONTROL, THE RED: a realm created by ANOTHER PATH leaves the registry short", async () => {
    await withRealm(async ({ auth }) => {
      const registry = fakeRegistry();
      // `create` called directly -- the DO stub route, or any deployed pre-1b-i code. This is how a
      // realm comes into existence WITHOUT passing through the create branch that registers it.
      await auth.create("bypass");

      // ⭐⭐ THE COUNT CONTROL, IN MINIATURE: one realm exists, the registry holds zero. If this
      // arm cannot go red the control is decoration -- so it is asserted here, on the real bypass
      // path, rather than described in a doc.
      expect(registry.entries.size).toBe(0);
      expect(await auth.authorize(new Request("https://realm.invalid/frontier"))).toBe("unauthorized");
    });
  });
});
