import { env, listDurableObjectIds, runInDurableObject } from "cloudflare:test";
import { beforeEach, expect, it } from "vitest";
import { reconcile, type ReconciliationEnv } from "../../reconciliation/run";

async function create() {
  const realm = crypto.randomUUID();
  const response = await env.REALMS.get(env.REALMS.idFromName(realm)).fetch("https://realm.test/realm/create", {
    method: "POST", headers: { "x-commonplace-realm-id": realm, "x-commonplace-realm-create": "1" },
  });
  expect(response.status).toBe(201); await response.text();
  expect(await env.REALM_REGISTRY.get(realm)).not.toBeNull();
  return realm;
}
async function storedCount() {
  let count = 0;
  for (const id of await listDurableObjectIds(env.REALMS)) {
    const hasStoredData = await runInDurableObject(env.REALMS.get(id), (_instance, state) =>
      state.storage.sql.exec("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' AND name NOT LIKE '_cf_%'").toArray().length > 0);
    if (hasStoredData) count++;
  }
  return { count, instrument: "local DO enumeration + independent user-table storage inspection" };
}
async function snapshot() {
  const result: Record<string, string | null> = {};
  for (const key of (await env.REALM_REGISTRY.list()).keys) result[key.name] = await env.REALM_REGISTRY.get(key.name);
  return result;
}
async function orphan() {
  const realm = await create();
  await runInDurableObject(env.REALMS.get(env.REALMS.idFromName(realm)), async (_i, state) => { await state.storage.deleteAll(); });
  return realm;
}
function withFetch(fetch: (input: RequestInfo, init?: RequestInit) => Promise<Response>): ReconciliationEnv {
  return { ...env, REALMS: {
    idFromName: env.REALMS.idFromName.bind(env.REALMS),
    get: (id) => new Proxy(env.REALMS.get(id), { get(target, property) {
      if (property === "fetch") return fetch;
      return Reflect.get(target, property);
    } }),
  } };
}
const deletion = { apply: true, lifecycleQuiesced: true, countStoredObjects: storedCount };
beforeEach(async () => {
  for (const key of (await env.REALM_REGISTRY.list()).keys) await env.REALM_REGISTRY.delete(key.name);
  expect((await env.REALM_REGISTRY.list()).keys).toHaveLength(0);
});

it("R1 R3 R4: dryrun preserves orphan bytes; explicit deletion removes only orphan; repeat removes zero", async () => {
  const live = await create(); const gone = await orphan();
  const before = await snapshot();
  const counts = await storedCount();
  expect(Object.keys(before)).toHaveLength(2); expect(counts.count).toBe(1);
  console.info("RECON BASE registry=2 independently stored DO=1 orphan row present=true");
  const dry = await reconcile(env, { countStoredObjects: storedCount });
  expect(dry.rows.find((r) => r.realm_id === gone)).toMatchObject({ verdict: "absent", cause: "not_found", action: "would_delete" });
  expect(dry.would_remove).toBe(1); expect(dry.removed).toBe(0);
  expect(await snapshot()).toEqual(before);
  await expect(reconcile(env, { apply: true, countStoredObjects: storedCount })).rejects.toThrow("lifecycle_quiescence_required");
  expect(await snapshot()).toEqual(before);
  const applied = await reconcile(env, deletion);
  expect(applied.rows.find((r) => r.realm_id === live)).toMatchObject({ verdict: "present", action: "keep" });
  expect(applied.rows.find((r) => r.realm_id === gone)).toMatchObject({ verdict: "absent", action: "deleted" });
  expect(applied.removed).toBe(1); expect(await env.REALM_REGISTRY.get(gone)).toBeNull();
  expect(await env.REALM_REGISTRY.get(live)).toBe(before[live]);
  const repeated = await reconcile(env, deletion);
  expect(repeated.removed).toBe(0); expect(repeated.would_remove).toBe(0);
  expect(repeated.registry_rows).toBe(1);
  console.info("R1/R3/R4 dryrun writes=0 apply removed=1 repeated removed=0");
});

it.each(["transport_error", "timeout", "http_5xx", "malformed_body", "unexpected_response", "capability_rejected"] as const)(
  "R2: %s is unknown and preserves the live realm registry bytes", async (cause) => {
    const realm = await create(); const before = await snapshot();
    const healthy = await reconcile(env, { countStoredObjects: storedCount });
    expect(healthy.rows).toHaveLength(1); expect(healthy.rows[0]).toMatchObject({ verdict: "present" });
    const broken = withFetch(async (_input, init) => {
      if (cause === "transport_error") throw new Error("fixture unreachable");
      if (cause === "timeout") return await new Promise<Response>((_resolve, reject) => {
        init?.signal?.addEventListener("abort", () => reject(new Error("fixture aborted")), { once: true });
      });
      if (cause === "http_5xx") return Response.json({ ok: false, error: { code: "not_found" } }, { status: 503 });
      if (cause === "malformed_body") return new Response("not json", { status: 404 });
      if (cause === "capability_rejected") return Response.json({ ok: false }, { status: 401 });
      return Response.json({ ok: false, error: { code: "other" } }, { status: 404 });
    });
    const report = await reconcile(broken, { ...deletion, timeoutMs: 20 });
    const after = await snapshot();
    console.info("R2 observed", { injected: cause, row: report.rows[0], row_retained: after[realm] === before[realm] });
    expect(after).toEqual(before);
    expect(report.rows).toEqual([{ realm_id: realm, verdict: "unknown", cause, action: "keep" }]);
    expect(report.removed).toBe(0); expect(await snapshot()).toEqual(before);
    console.info(`R2 healthy=present injected=${cause} verdict=unknown removed=0 byte-identical=true`);
  },
);

it.each(["registry_recheck_failed", "registry_row_changed"] as const)("R2 recheck: %s never deletes", async (cause) => {
  const realm = await orphan(); const original = await env.REALM_REGISTRY.get(realm);
  let reads = 0; let deletes = 0;
  const registry: ReconciliationEnv["REALM_REGISTRY"] = {
    list: env.REALM_REGISTRY.list.bind(env.REALM_REGISTRY),
    get: async () => {
      reads++;
      if (reads === 2) {
        if (cause === "registry_recheck_failed") throw new Error("fixture read failed");
        return "replacement row fixture";
      }
      return original;
    },
    delete: async () => { deletes++; },
  };
  const report = await reconcile({ ...env, REALM_REGISTRY: registry }, deletion);
  expect(report.rows[0]).toMatchObject({ verdict: "unknown", cause, action: "keep" });
  expect(deletes).toBe(0); expect(await env.REALM_REGISTRY.get(realm)).toBe(original);
});

it("R5: an unregistered live realm produces independent 1 vs 2; unknown count stays unknown", async () => {
  await create(); const hidden = await create();
  expect(Object.keys(await snapshot())).toHaveLength(2); expect((await storedCount()).count).toBe(2);
  await env.REALM_REGISTRY.delete(hidden);
  const report = await reconcile(env, { countStoredObjects: storedCount });
  expect(report.registry_rows).toBe(1); expect(report.stored_objects?.count).toBe(2);
  expect(report.registry_minus_stored_objects).toBe(-1); expect(report.rows).toHaveLength(1);
  const unavailable = await reconcile(env, { countStoredObjects: async () => { throw new Error("fixture blind counter"); } });
  expect(unavailable.stored_objects).toBeNull(); expect(unavailable.registry_minus_stored_objects).toBeNull();
  expect(unavailable.count_cause).toBe("stored_object_count_unavailable");
  console.info("R5 before KV=2 DO=2 after KV=1 DO=2 delta=-1; failed counter=null, never zero");
});

it("enumeration failure preserves rows and reports the partial inventory as unknown", async () => {
  const realm = await orphan(); const before = await snapshot(); let pages = 0;
  const registry: ReconciliationEnv["REALM_REGISTRY"] = {
    ...env.REALM_REGISTRY,
    get: env.REALM_REGISTRY.get.bind(env.REALM_REGISTRY), delete: env.REALM_REGISTRY.delete.bind(env.REALM_REGISTRY),
    list: async () => { if (pages++) throw new Error("fixture failed page");
      return { keys: [{ name: realm }], list_complete: false, cursor: "next", cacheStatus: null }; },
  };
  const result = await reconcile({ ...env, REALM_REGISTRY: registry }, deletion);
  expect(result.registry_enumeration).toBe("unknown"); expect(result.registry_minus_stored_objects).toBeNull();
  expect(result.rows[0]).toMatchObject({ verdict: "unknown", cause: "registry_enumeration_failed" });
  expect(await snapshot()).toEqual(before);
});
