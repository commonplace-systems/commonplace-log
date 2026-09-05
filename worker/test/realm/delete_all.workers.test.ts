// REALM-REMOVE-1a — the load-bearing premise, MEASURED rather than quoted.
//
// The Cloudflare control plane has no DELETE for a Durable Object instance (two endpoints, both
// GET), so the only per-realm removal mechanism is `state.storage.deleteAll()` from INSIDE the
// object. Cloudflare's storage docs say deleteAll "removes the entire contents of a Durable
// Object's private SQLite database, including both SQL data and key-value data" -- but that is a
// docs sentence, and this Worker keeps the realm in SQL (`realm_meta`), not in the KV side.
//
// ⭐ If deleteAll cleared only the key-value half, `realm_meta` would survive, `authorize()` would
// still find the stored hash, and a "removed" realm would still authenticate. That is the failure
// this file exists to rule out.
//
// ⛔ EVERY ARM CARRIES ITS POSITIVE CONTROL IN THE SAME TEST BODY: the pre-delete assertion runs
// against the same object, so "gone after" cannot be confused with "never there".
import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { REALM_CREATE_HEADER, RealmAuth, handlePublicRealmRequest } from "../../src/realm/realm_auth";
import { initRealmMetaSchema } from "../../src/realm/schema";

let sequence = 0;

async function withRealm<T>(
  fn: (ctx: {
    auth: RealmAuth;
    storage: DurableObjectStorage;
    sql: SqlStorage;
    create: () => Promise<Response>;
    call: (secret: string) => Promise<Response>;
  }) => Promise<T>,
): Promise<T> {
  const realmId = `deleteall-${Date.now()}-${sequence++}`;
  const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName(realmId));
  return await runInDurableObject(stub, async (_instance, state) => {
    const sql = state.storage.sql;
    initRealmMetaSchema(sql);
    const auth = new RealmAuth(sql, state.storage);
    const inner = async () => Response.json({ ok: true, reached: true }, { status: 200 });
    const create = () =>
      handlePublicRealmRequest(
        new Request("https://realm.invalid/realm/create", {
          method: "POST",
          headers: { [REALM_CREATE_HEADER]: "1", "x-commonplace-realm-id": realmId },
        }),
        auth,
        inner,
        undefined,
        true, // allowUnboundRegistry: this file measures storage, not registration
      );
    const call = (secret: string) =>
      handlePublicRealmRequest(
        new Request("https://realm.invalid/frontier", {
          method: "POST",
          headers: { authorization: `Bearer ${secret}` },
        }),
        auth,
        inner,
      );
    return await fn({ auth, storage: state.storage, sql, create, call });
  });
}

function tableCount(sql: SqlStorage, name: string): number {
  const rows = [
    ...sql.exec("SELECT count(*) AS n FROM sqlite_master WHERE type='table' AND name = ?", name),
  ];
  return Number(rows[0].n);
}

describe("REALM-REMOVE-1a: does deleteAll() drop SQL, not just key-value?", () => {
  it("D1 removes the realm: a write capability that authorised before reads not_found after", async () => {
    await withRealm(async ({ auth, storage, create, call }) => {
      const created = await create();
      expect(created.status).toBe(201);
      const secret = (await created.json<{ realm_secret: string }>()).realm_secret;

      // POSITIVE CONTROL — the realm is really there before the act.
      expect(await auth.authorize(bearer(secret))).toBe("write");
      expect((await call(secret)).status).toBe(200);

      await storage.deleteAll();

      // THE MEASUREMENT. `not_found` (not `unauthorized`) is the discriminator: it means the
      // stored hash is GONE, not that a wrong secret was presented.
      expect(await auth.authorize(bearer(secret))).toBe("not_found");
      expect((await call(secret)).status).toBe(404);
    });
  });

  it("D2 drops the SQL TABLE itself, not merely its rows", async () => {
    await withRealm(async ({ sql, storage, create }) => {
      expect((await create()).status).toBe(201);

      sql.exec("CREATE TABLE probe (k TEXT PRIMARY KEY, v TEXT)");
      sql.exec("INSERT INTO probe (k, v) VALUES ('a', 'alpha')");

      // POSITIVE CONTROL — both tables exist and the row is readable.
      expect(tableCount(sql, "realm_meta")).toBe(1);
      expect(tableCount(sql, "probe")).toBe(1);
      expect([...sql.exec("SELECT v FROM probe WHERE k = 'a'")][0].v).toBe("alpha");

      await storage.deleteAll();

      // ⭐ Table COUNT, not row count: rows-gone-tables-kept would still be a real database
      // holding a realm's shape, and this arm would pass on a partial delete if it counted rows.
      expect(tableCount(sql, "realm_meta")).toBe(0);
      expect(tableCount(sql, "probe")).toBe(0);
    });
  });

  it("D3 is not a mock: the same object is usable again afterwards, so removal is not corruption", async () => {
    await withRealm(async ({ sql, auth, storage, create }) => {
      expect((await create()).status).toBe(201);
      await storage.deleteAll();
      expect(await auth.authorize(bearer("whatever"))).toBe("not_found");

      // Recreating the schema in the SAME object works ⇒ `hasStoredData` false is a clean slate,
      // which is what BACKUP-1c's create-and-destroy rehearsal needs the object to be.
      initRealmMetaSchema(sql);
      expect(tableCount(sql, "realm_meta")).toBe(1);
    });
  });
});

function bearer(secret: string): Request {
  return new Request("https://realm.invalid/frontier", {
    method: "POST",
    headers: { authorization: `Bearer ${secret}` },
  });
}
