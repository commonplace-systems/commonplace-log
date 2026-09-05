import { SELF, env, runInDurableObject } from "cloudflare:test";
import { kvRegistry, type RealmRegistry } from "../../src/realm/registry";
import { describe, expect, it } from "vitest";
import { handleRealmRequest } from "../../src/realm/http";
import { RealmContainer } from "../../src/realm/container";
import { RealmNode } from "../../src/realm/node";
import {
  READ_CAPABILITY_PATH,
  REALM_CREATE_HEADER,
  REALM_ID_HEADER,
  RealmAuth,
  handlePublicRealmRequest,
} from "../../src/realm/realm_auth";
import { initRealmMetaSchema } from "../../src/realm/schema";
import { RealmStore } from "../../src/realm/store";

// DO-local own-resource path: ingress forwards DELETE /realms/{realm_id} to /.
// /realm would instead invent a nested public resource /realms/{realm_id}/realm.
const REMOVE_PATH = "/";
const LOG_ID = "survival-probe";
let sequence = 0;

type Call = (path: string, secret: string, method?: string, body?: unknown) => Promise<Response>;

async function withRealm(
  fn: (call: Call, write: string) => Promise<void>,
  options: {
    registry?: RealmRegistry;
    allowUnbound?: boolean;
    wipe?: (storage: DurableObjectStorage) => Promise<void>;
  } = {},
): Promise<void> {
  const realmId = `realm-remove-${Date.now()}-${sequence++}`;
  const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName(realmId));
  await runInDurableObject(stub, async (_instance, state) => {
    initRealmMetaSchema(state.storage.sql);
    const auth = new RealmAuth(state.storage.sql, state.storage);
    const store = new RealmStore(state.storage.sql, state.storage);
    // Real dispatcher and real Workers SQLite storage, not an always-successful inner handler
    // or a deleteAll fake. This measures the public handler, not the ingress/Container lane.
    const authorized = (request: Request) => handleRealmRequest(request, store);
    const created = await handlePublicRealmRequest(
      new Request("https://realm.invalid/realm/create", {
        method: "POST",
        headers: { [REALM_CREATE_HEADER]: "1", [REALM_ID_HEADER]: realmId },
      }),
      auth,
      authorized,
      options.registry,
      true, // Explicit unbound fixture allows R2 to mint its own read capability.
    );
    expect(created.status).toBe(201);
    const { realm_secret: write } = await created.json<{ realm_secret: string }>();
    expect(/^[0-9a-f]{64}$/.test(write)).toBe(true);

    const call: Call = (path, secret, method = "POST", body) =>
      handlePublicRealmRequest(
        new Request(`https://realm.invalid${path}`, {
          method,
          headers: {
            ...(secret === "" ? {} : { authorization: `Bearer ${secret}` }),
            "content-type": "application/json",
            [REALM_ID_HEADER]: realmId, // Trusted DO-local fixture, as supplied by ingress.
          },
          body: body === undefined ? undefined : JSON.stringify(body),
        }),
        auth,
        authorized,
        options.registry,
        options.allowUnbound ?? true,
        () => options.wipe === undefined ? state.storage.deleteAll() : options.wipe(state.storage),
      );

    expect((await call("/create-log", write, "POST", { log_id: LOG_ID })).status).toBe(201);
    const before = await call("/frontier", write, "POST", { log_id: LOG_ID });
    expect(before.status).toBe(200);
    expect(await before.json()).toEqual({ ok: true, frontier: { writers: [] } });
    await fn(call, write);
  });
}

const registryKV = (env as unknown as { REALM_REGISTRY: KVNamespace }).REALM_REGISTRY;

async function gateway(realmId: string, path: string, secret: string, method = "POST", body?: unknown,
  extraHeaders: Record<string, string> = {}) {
  const response = await SELF.fetch(`https://gateway.invalid/realms/${realmId}${path}`, {
    method,
    headers: {
      ...(secret === "" ? {} : { authorization: `Bearer ${secret}` }),
      "content-type": "application/json",
      ...extraHeaders,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  // Drain the cross-Worker stream even when an arm checks only status, before
  // isolated-storage cleanup can begin. The returned response is local/buffered.
  const bytes = await response.arrayBuffer();
  return new Response(response.status === 204 ? null : bytes, {
    status: response.status, statusText: response.statusText, headers: response.headers,
  });
}

async function createGatewayRealm(realmId: string): Promise<string> {
  const created = await gateway(realmId, "", env.GATEWAY_TOKEN, "POST", {});
  expect(created.status).toBe(201);
  const body = await created.json<{ realm_secret: string; registry: string }>();
  expect(body.registry).toBe("registered");
  return body.realm_secret;
}

async function registryCount(): Promise<number> {
  let cursor: string | undefined;
  let count = 0;
  do {
    const page = await registryKV.list({ cursor });
    count += page.keys.length;
    if (page.list_complete) return count;
    cursor = page.cursor;
  } while (true);
}

describe("REALM-REMOVE-1b", () => {
  it("R1: gateway create and entry write, positive frontier, removal, same-capability not_found", async () => {
    const realmId = crypto.randomUUID();
    const write = await createGatewayRealm(realmId);
    expect((await gateway(realmId, "/create-log", write, "POST", { log_id: LOG_ID })).status).toBe(201);
    const entry = {
      entry_id: "entry-one", writer_id: "writer-one", writer_seq: 1,
      prev_entry_id: null, created_at: "2026-09-04T00:00:00Z",
    };
    const committed = await gateway(realmId, "/commit", write, "POST", {
      log_id: LOG_ID, expected_revision: 0, expected_epoch: 0,
      insert_entries: [{ ...entry, canonical_bytes: btoa(JSON.stringify(entry)) }],
      put_tips: [{ writer_id: entry.writer_id, last_seq: 1, last_entry_id: entry.entry_id }],
    });
    expect(committed.status).toBe(200);
    const before = await gateway(realmId, "/frontier", write, "POST", { log_id: LOG_ID });
    expect(before.status, "BLIND unless the same realm/log is readable before removal").toBe(200);
    expect(await before.json()).toEqual({ ok: true, frontier: {
      writers: [{ writer_id: entry.writer_id, seq: 1, entry_id: entry.entry_id }],
    } });
    console.info("R1 CONTROL entry commit=%d frontier=%d writers=1", committed.status, before.status);
    const removed = await gateway(realmId, "", write, "DELETE");
    expect(removed.status).toBe(204);
    expect(await removed.text()).toBe("");
    const after = await gateway(realmId, "/frontier", write, "POST", { log_id: LOG_ID });
    expect(after.status).toBe(404);
    expect(await after.json()).toEqual({ ok: false, error: { code: "not_found" } });
    console.info("R1 RESULT delete=%d same-write frontier=%d", removed.status, after.status);
  });

  it("R2: reachable WRITE deletion refuses a read capability without removing its realm", async () => {
    // Mandatory precondition IN THIS TEST: an unknown path already gets forbidden_scope for
    // READ. Without a WRITE 204 first, the scope/survival assertions could pass before removal
    // exists. Sacrifice a different DO so this control cannot destroy the refusal subject.
    await withRealm(async (call, write) => {
      const removed = await call(REMOVE_PATH, write, "DELETE");
      expect(removed.status, "WRITE DELETE / must reach removal before testing READ scope").toBe(204);
      expect(await removed.text()).toBe("");
    });

    await withRealm(async (call, write) => {
      const minted = await call(READ_CAPABILITY_PATH, write);
      expect(minted.status).toBe(201);
      const { read_secret: read } = await minted.json<{ read_secret: string }>();
      expect(/^[0-9a-f]{64}$/.test(read)).toBe(true);

      // Positive control: this exact read capability reaches the real log before the refusal.
      const before = await call("/frontier", read, "POST", { log_id: LOG_ID });
      expect(before.status).toBe(200);
      expect(await before.json()).toEqual({ ok: true, frontier: { writers: [] } });

      console.info("R2 CONTROL write removal reached=204 read frontier=%d", before.status);
      const refused = await call(REMOVE_PATH, read, "DELETE");
      expect(refused.status).toBe(403);
      expect(await refused.json()).toEqual({ ok: false, error: { code: "forbidden_scope" } });

      // A refusal that nevertheless deletes storage must fail: same realm, log, and READ secret.
      const after = await call("/frontier", read, "POST", { log_id: LOG_ID });
      expect(after.status).toBe(200);
      expect(await after.json()).toEqual({ ok: true, frontier: { writers: [] } });
      console.info("R2 RESULT read delete=%d forbidden_scope surviving frontier=%d", refused.status, after.status);
    });
  });

  it("R3: repeat and never-created canonical removals are empty 204s", async () => {
    const realmId = crypto.randomUUID();
    const write = await createGatewayRealm(realmId);
    const first = await gateway(realmId, "", write, "DELETE");
    const second = await gateway(realmId, "", write, "DELETE");
    const neverId = crypto.randomUUID();
    const absentControl = await gateway(neverId, "/frontier", "unassigned", "POST", { log_id: LOG_ID });
    expect(absentControl.status).toBe(404);
    // ⭐ plan row 941-bis: a DELETE on an EMPTY DO is inert, and the count is what proves it.
    // ⛔ The status alone cannot: a 204 that ALSO erased a registry row looks identical from here,
    // and that row would belong to whichever realm id the caller guessed.
    const countBefore = await registryCount();
    const never = await gateway(neverId, "", "unassigned", "DELETE");
    const countAfter = await registryCount();
    expect(countAfter, "an unauthenticated removal must have NO side effect").toBe(countBefore);
    console.info("R3 INERT never-created delete: registry count %d -> %d", countBefore, countAfter);
    for (const response of [first, second, never]) {
      expect(response.status).toBe(204);
      expect(await response.text()).toBe("");
    }
    const nonRoot = await gateway(neverId, "/realm/read-capability", "unassigned", "DELETE");
    expect(nonRoot.status).toBe(404);
    console.info("R3 RESULT first=%d repeat=%d never-created=%d non-root=%d", first.status, second.status, never.status, nonRoot.status);
  });

  it("R4: registry failure is named after real wipe; an unauthenticated retry RETAINS the KV row", async () => {
    const events: string[] = [];
    const real = kvRegistry(registryKV)!;
    let registeredId = "";
    let failDelete = true;
    const registry: RealmRegistry = {
      async put(id, capability) { registeredId = id; await real.put(id, capability); },
      async delete(id) {
        events.push("registry");
        if (failDelete) throw new Error("injected registry delete failure");
        await real.delete(id);
      },
    };
    await withRealm(async (call, write) => {
      expect((await registryKV.get(registeredId)) === null).toBe(false);
      const before = await call("/frontier", write, "POST", { log_id: LOG_ID });
      expect(before.status).toBe(200);
      console.info("R4 CONTROL frontier=%d registry row present=true", before.status);
      const failed = await call(REMOVE_PATH, write, "DELETE");
      expect(failed.status).toBe(503);
      const body = await failed.json();
      expect(body).toEqual({ ok: false, error: { code: "registry_delete_failed" }, registry: "registry_delete_failed" });
      expect(events).toEqual(["wipe", "registry"]);
      const after = await call("/frontier", write, "POST", { log_id: LOG_ID });
      expect(after.status).toBe(404);
      expect((await registryKV.get(registeredId)) === null).toBe(false);
      console.info("R4 RESULT delete=%d registry_delete_failed frontier=%d order=%s", failed.status, after.status, events.join(","));
      // ⛔ REVERSED DELIBERATELY (plan row 941-bis, adjudicated by the reviewer): this arm used to
      // assert that an unauthenticated retry CLEANED the orphan row. It must now assert the row
      // SURVIVES. An unauthenticated removal has NO side effect, because "204 on an empty DO" and
      // "any caller who guesses an id erases its registry row" are the same code path.
      // ⭐ The repair Astra built here is not deleted, it MOVED: BACKUP-1b-iii reconciles rows whose
      // DO reads not_found, under the Worker's own binding, with the orphan count as its control.
      failDelete = false;
      const retried = await call(REMOVE_PATH, "", "DELETE");
      expect(retried.status).toBe(204);
      expect((await registryKV.get(registeredId)) === null).toBe(false);
      // ⭐ THE SIDE-EFFECT ASSERTION, not merely the status: no second wipe and no second registry
      // call. A 204 that still wiped would pass a status-only arm.
      expect(events).toEqual(["wipe", "registry"]);
      console.info("R4 RETRY absent-auth delete=%d registry row RETAINED=true events=%s", retried.status, events.join(","));
    }, {
      registry,
      async wipe(storage) { await storage.deleteAll(); events.push("wipe"); },
    });
  });

  it("R4 storage failure never drops the registry row or live realm", async () => {
    const events: string[] = [];
    const real = kvRegistry(registryKV)!;
    let registeredId = "";
    const registry: RealmRegistry = {
      async put(id, capability) { registeredId = id; await real.put(id, capability); },
      async delete(id) { events.push("registry"); await real.delete(id); },
    };
    await withRealm(async (call, write) => {
      expect((await registryKV.get(registeredId)) === null).toBe(false);
      await expect(call(REMOVE_PATH, write, "DELETE")).rejects.toThrow("injected storage failure");
      expect(events).toEqual(["wipe_failed"]);
      expect((await registryKV.get(registeredId)) === null).toBe(false);
      const after = await call("/frontier", write, "POST", { log_id: LOG_ID });
      expect(after.status).toBe(200);
      console.info("R4 STORAGE FAILURE order=%s registry row retained=true frontier=%d", events.join(","), after.status);
    }, {
      registry,
      async wipe() { events.push("wipe_failed"); throw new Error("injected storage failure"); },
    });
  });

  it("R5: real KV inventory loses exactly the removed realm and ignores spoofed identity", async () => {
    const initial = await registryCount();
    const realmId = crypto.randomUUID();
    const otherId = crypto.randomUUID();
    const write = await createGatewayRealm(realmId);
    const otherWrite = await createGatewayRealm(otherId);
    const before = await registryCount();
    expect(before).toBe(initial + 2);
    expect((await registryKV.get(realmId)) === null).toBe(false);
    expect((await registryKV.get(otherId)) === null).toBe(false);
    console.info("R5 CONTROL initial=%d before=%d both created rows present=true", initial, before);
    const removed = await gateway(realmId, "", write, "DELETE", undefined, { [REALM_ID_HEADER]: otherId });
    expect(removed.status).toBe(204);
    const after = await registryCount();
    expect(before).toBe(after + 1);
    expect((await registryKV.get(realmId)) === null).toBe(true);
    expect((await registryKV.get(otherId)) === null).toBe(false);
    expect((await gateway(otherId, "/create-log", otherWrite, "POST", { log_id: LOG_ID })).status).toBe(201);
    console.info("R5 RESULT before=%d after=%d delta=%d target absent=true other retained=true", before, after, before - after);
  });

  it("removal keeps wrong/missing bearer, READ scope, root-only and revocation boundaries", async () => {
    const realmId = crypto.randomUUID();
    const write = await createGatewayRealm(realmId);
    expect((await gateway(realmId, "/create-log", write, "POST", { log_id: LOG_ID })).status).toBe(201);
    const row = await registryKV.get<{ read_capability: string }>(realmId, "json");
    expect(row === null).toBe(false);
    const read = row!.read_capability;
    expect((await gateway(realmId, "/frontier", read, "POST", { log_id: LOG_ID })).status).toBe(200);
    for (const secret of ["", "wrong-bearer"]) {
      expect((await gateway(realmId, "", secret, "DELETE")).status).toBe(401);
    }
    const forbidden = await gateway(realmId, "", read, "DELETE");
    expect(forbidden.status).toBe(403);
    expect(await forbidden.json()).toEqual({ ok: false, error: { code: "forbidden_scope" } });
    // Trailing slash is not the canonical public removal, even with a spoofed header.
    expect((await gateway(realmId, "/", write, "DELETE", undefined, { [REALM_ID_HEADER]: realmId })).status).toBe(400);
    expect((await gateway(realmId, READ_CAPABILITY_PATH, write, "DELETE")).status).toBe(204);
    expect((await gateway(realmId, "/frontier", write, "POST", { log_id: LOG_ID })).status).toBe(200);
    expect((await gateway(realmId, "/frontier", read, "POST", { log_id: LOG_ID })).status).toBe(401);
    expect((await registryKV.get(realmId)) === null).toBe(false);
    console.info("SECURITY wrong/missing=401 read delete=403 noncanonical=400 revocation=204 write frontier=200 revoked read=401");
  });

  it("both lane dispatchers gate creation and removal through native blockConcurrencyWhile only", async () => {
    // This is a lane-wiring check, NOT a concurrent-event/recreation race proof.
    // The receiver supplies real storage and the native DO gate, recording which
    // operations each actual fetch implementation puts inside that gate.
    for (const lane of [
      { name: "container", fetch: RealmContainer.prototype.fetch },
      { name: "node", fetch: RealmNode.prototype.fetch },
    ]) {
      const realmId = `lifecycle-${lane.name}-${Date.now()}-${sequence++}`;
      const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName(realmId));
      await runInDurableObject(stub, async (_instance, state) => {
        const auth = new RealmAuth(state.storage.sql, state.storage);
        const store = new RealmStore(state.storage.sql, state.storage);
        const gated: string[] = [];
        let operation = "";
        const receiver = {
          auth, store,
          env: { REALM_TEST_LEVERS: "1" },
          ctx: {
            storage: state.storage,
            async blockConcurrencyWhile<T>(fn: () => Promise<T>): Promise<T> {
              gated.push(operation);
              return await state.blockConcurrencyWhile(fn);
            },
          },
          fetchAuthorized: (request: Request) => handleRealmRequest(request, store),
        };
        const call = async (path: string, method: string, secret = "", body?: unknown) => {
          operation = `${method} ${path}`;
          return await lane.fetch.call(receiver as unknown as RealmContainer & RealmNode,
            new Request(`https://realm.invalid${path}`, {
              method,
              headers: {
                [REALM_CREATE_HEADER]: "1", [REALM_ID_HEADER]: realmId,
                ...(secret === "" ? {} : { authorization: `Bearer ${secret}` }),
                "content-type": "application/json",
              },
              body: body === undefined ? undefined : JSON.stringify(body),
            }));
        };
        const created = await call("/realm/create", "POST");
        expect(created.status).toBe(201);
        const { realm_secret: write } = await created.json<{ realm_secret: string }>();
        const log = await call("/create-log", "POST", write, { log_id: LOG_ID });
        expect(log.status).toBe(201);
        await log.arrayBuffer();
        const before = await call("/frontier", "POST", write, { log_id: LOG_ID });
        expect(before.status).toBe(200);
        await before.arrayBuffer();
        expect(gated).toEqual(["POST /realm/create"]);
        const removed = await call("/", "DELETE", write);
        expect(removed.status).toBe(204);
        expect(gated).toEqual(["POST /realm/create", "DELETE /"]);
        console.info("LIFECYCLE WIRING lane=%s gate=%s ordinary frontier=%d removal=%d", lane.name, gated.join(","), before.status, removed.status);
      });
    }
  });

  it("unbound registry defaults to refusal before wiping a live realm", async () => {
    const events: string[] = [];
    await withRealm(async (call, write) => {
      const failed = await call(REMOVE_PATH, write, "DELETE");
      expect(failed.status).toBe(503);
      expect(await failed.json()).toEqual({ ok: false, error: {
        code: "registry_not_bound", details: { binding: "REALM_REGISTRY" },
      } });
      expect(events).toEqual([]);
      expect((await call("/frontier", write, "POST", { log_id: LOG_ID })).status).toBe(200);
      console.info("UNBOUND CONTROL delete=503 registry_not_bound wipe calls=0 frontier=200");
    }, { allowUnbound: false, async wipe(storage) { events.push("wipe"); await storage.deleteAll(); } });
  });
});
