import { SELF, env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import {
  REALM_CREATE_HEADER as LEGACY_CREATE_HEADER,
  REALM_ID_HEADER as LEGACY_ID_HEADER,
  RealmAuth as LegacyRealmAuth,
  handlePublicRealmRequest as legacyPublicRequest,
} from "./fixtures/legacy-76f9028/realm_auth";
import { handleRealmRequest as legacyRealmRequest } from "./fixtures/legacy-76f9028/http";
import { RealmStore as LegacyRealmStore } from "./fixtures/legacy-76f9028/store";
import type { RealmRegistry as LegacyRegistry } from "./fixtures/legacy-76f9028/registry";

/**
 * LOG-LEGACY-REALM-FIX-1. The 2026-09-13 beta-next outage: a realm whose SQLite schema was
 * created by the code deployed before that day (`76f9028`, Worker `c9515b6d`) answered
 * `POST /frontier` with 500 `no such table: restore_markers` once the restore code was deployed.
 *
 * ⛔ THE LEGACY REALM IS BUILT BY THE OLD CODE ITSELF, NOT BY A HAND-WRITTEN IMITATION OF IT.
 * `fixtures/legacy-76f9028/*.ts` are byte-exact copies of `worker/src/realm/*.ts` at `76f9028`,
 * pinned by git blob id in `legacy_fixture_pin.test.ts`. Realm creation, read-capability mint,
 * `/create-log`, `/take-lease` and `/commit` below all run through that code, with that era's
 * request shapes, on real DO SQLite. Every assertion after the seed runs the CURRENT code through
 * the gateway, the way production traffic arrives.
 */

type Json = Record<string, any>;

const RESTORE_ERA_TABLES = ["realm_allocations", "restore_bundle_logs", "restore_bundles", "restore_markers"];
const LEGACY_TABLES = ["entries", "logs", "realm_meta", "writer_tips"];

interface LegacySeed {
  realm: string;
  writeSecret: string;
  readSecret: string;
  logId: string;
  writerId: string;
  entryIds: string[];
}

function fakeRegistry(): LegacyRegistry & { capability: string | null } {
  return {
    capability: null,
    async put(_realm, readCapability) {
      this.capability = readCapability;
    },
    async delete() {
      this.capability = null;
    },
  };
}

function canonical(logId: string, entryId: string, writerId: string, seq: number, prev: string | null): string {
  return btoa(JSON.stringify({
    body: { n: seq },
    created_at: "2026-09-05T15:30:00Z",
    entry_id: entryId,
    log_id: logId,
    prev_entry_id: prev,
    version: 1,
    writer_id: writerId,
    writer_seq: seq,
  }));
}

function tables(sql: SqlStorage): string[] {
  return sql
    .exec("SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%' ORDER BY name")
    .toArray()
    .map((row) => String(row.name));
}

function catalog(sql: SqlStorage): Json[] {
  return sql.exec("SELECT type, name, tbl_name, sql FROM sqlite_master ORDER BY type, name").toArray();
}

function rows(sql: SqlStorage): Json {
  const hex = (value: unknown) => Array.from(new Uint8Array(value as ArrayBuffer), (b) => b.toString(16).padStart(2, "0")).join("");
  return {
    logs: sql.exec("SELECT * FROM logs ORDER BY log_id").toArray(),
    entries: sql.exec("SELECT * FROM entries ORDER BY arrival_seq").toArray()
      .map((row) => ({ ...row, canonical_json: hex(row.canonical_json) })),
    tips: sql.exec("SELECT * FROM writer_tips ORDER BY log_id, writer_id").toArray(),
    meta: sql.exec("SELECT * FROM realm_meta").toArray()
      .map((row) => ({ ...row, secret_hash: hex(row.secret_hash), read_secret_hash: row.read_secret_hash === null ? null : hex(row.read_secret_hash) })),
  };
}

async function inRealm<T>(realm: string, fn: (sql: SqlStorage) => T): Promise<T> {
  return await runInDurableObject(env.REALM_CONTAINER.getByName(realm), (_instance, state) => fn(state.storage.sql));
}

/** Create a realm, and optionally a two-entry log, entirely through the `76f9028` code. */
async function seedLegacyRealm(withLog: boolean): Promise<LegacySeed> {
  const realm = crypto.randomUUID();
  const logId = crypto.randomUUID();
  const writerId = crypto.randomUUID();
  const entryIds = [crypto.randomUUID(), crypto.randomUUID()];
  return await runInDurableObject(env.REALM_CONTAINER.getByName(realm), async (_instance, state) => {
    const auth = new LegacyRealmAuth(state.storage.sql, state.storage);
    const store = new LegacyRealmStore(state.storage.sql, state.storage);
    const registry = fakeRegistry();
    const call = async (path: string, body: unknown, headers: Record<string, string>) => {
      const response = await legacyPublicRequest(
        new Request(`https://realm.invalid${path}`, {
          method: "POST",
          headers: { "content-type": "application/json", ...headers },
          body: JSON.stringify(body),
        }),
        auth,
        async (authorized) => await legacyRealmRequest(authorized, store),
        registry,
      );
      return { status: response.status, json: await response.json() as Json };
    };

    const created = await call("/realm/create", {}, { [LEGACY_CREATE_HEADER]: "1", [LEGACY_ID_HEADER]: realm });
    expect(created).toMatchObject({ status: 201, json: { ok: true, registry: "registered" } });
    const writeSecret = String(created.json.realm_secret);
    const readSecret = registry.capability!;
    expect(readSecret).toMatch(/^[0-9a-f]{64}$/);

    if (withLog) {
      const bearer = { authorization: `Bearer ${writeSecret}` };
      expect(await call("/create-log", { log_id: logId, format_version: 1, created_at: "2026-09-05T15:30:00Z" }, bearer))
        .toEqual({ status: 201, json: { ok: true } });
      const lease = await call("/take-lease", { log_id: logId }, bearer);
      expect(lease).toMatchObject({ status: 200, json: { ok: true, lease_epoch: 1, writer_id: expect.any(String) } });
      // The realm assigns the document writer at first lease; entries are written under that id.
      const leased = String(lease.json.writer_id);
      let prev: string | null = null;
      let revision = 0;
      for (const [index, entryId] of entryIds.entries()) {
        const seq = index + 1;
        const committed = await call("/commit", {
          log_id: logId,
          expected_revision: revision,
          expected_epoch: 1,
          insert_entries: [{
            entry_id: entryId,
            writer_id: leased,
            writer_seq: seq,
            prev_entry_id: prev,
            created_at: "2026-09-05T15:30:00Z",
            canonical_bytes: canonical(logId, entryId, leased, seq, prev),
          }],
          put_tips: [{ writer_id: leased, last_seq: seq, last_entry_id: entryId }],
        }, bearer);
        expect(committed).toEqual({ status: 200, json: { ok: true, revision: revision + 1 } });
        revision += 1;
        prev = entryId;
      }
      return { realm, writeSecret, readSecret, logId, writerId: leased, entryIds };
    }
    return { realm, writeSecret, readSecret, logId, writerId, entryIds };
  });
}

async function gateway(realm: string, path: string, bearer: string | null, body: unknown, method = "POST") {
  const headers = new Headers({ "content-type": "application/json" });
  if (bearer !== null) headers.set("authorization", `Bearer ${bearer}`);
  const response = await SELF.fetch(`https://gateway.invalid/realms/${realm}${path}`, {
    method,
    headers,
    body: method === "DELETE" ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let json: Json | null = null;
  try { json = text.length === 0 ? null : JSON.parse(text) as Json; } catch { json = { raw: text }; }
  return { status: response.status, json };
}

describe("LOG-LEGACY-REALM-FIX-1: a realm whose schema came from 76f9028", () => {
  it("control: the fixture realm has exactly the 76f9028 tables and none of the restore-era tables", async () => {
    const seed = await seedLegacyRealm(true);
    const present = await inRealm(seed.realm, tables);
    // Positive control first: a blind instrument would also report the restore tables absent.
    expect(present).toEqual(LEGACY_TABLES);
    for (const table of RESTORE_ERA_TABLES) expect(present).not.toContain(table);
    const seeded = await inRealm(seed.realm, rows);
    expect(seeded.entries).toHaveLength(2);
    expect(seeded.logs).toMatchObject([{ log_id: seed.logId, revision: 2, lease_epoch: 1, document_writer_id: seed.writerId }]);
  });

  it("every ordinary READ route answers on current code, reads the prior data back, and writes nothing", async () => {
    const seed = await seedLegacyRealm(true);
    const catalogBefore = await inRealm(seed.realm, catalog);
    const rowsBefore = await inRealm(seed.realm, rows);

    for (const [label, secret] of [["write", seed.writeSecret], ["read", seed.readSecret]] as const) {
      const frontier = await gateway(seed.realm, "/frontier", secret, { log_id: seed.logId });
      console.info("LEGACY frontier", label, frontier.status, JSON.stringify(frontier.json));
      expect(frontier, `frontier ${label}`).toEqual({ status: 200, json: { ok: true, frontier: { writers: [
        { writer_id: seed.writerId, seq: 2, entry_id: seed.entryIds[1] },
      ] } } });

      const readSet = await gateway(seed.realm, "/read-set", secret, {
        log_id: seed.logId,
        writers: [seed.writerId],
        coordinates: [{ writer_id: seed.writerId, writer_seq: 1 }],
        entry_ids: [seed.entryIds[1]],
      });
      expect(readSet, `read-set ${label}`).toMatchObject({ status: 200, json: { ok: true, read_set: {
        log_id: seed.logId, format_version: 1, revision: 2, lease_epoch: 1, document_writer_id: seed.writerId,
        tips: [{ writer_id: seed.writerId, last_seq: 2, last_entry_id: seed.entryIds[1] }],
        coordinates: [{ writer_id: seed.writerId, writer_seq: 1, canonical_bytes: canonical(seed.logId, seed.entryIds[0]!, seed.writerId, 1, null) }],
        entry_ids: [{ entry_id: seed.entryIds[1], canonical_bytes: canonical(seed.logId, seed.entryIds[1]!, seed.writerId, 2, seed.entryIds[0]!) }],
      } } });

      const readWriter = await gateway(seed.realm, "/read-writer", secret, {
        log_id: seed.logId, writer_id: seed.writerId, after_seq: 0, limit: 10,
      });
      expect(readWriter, `read-writer ${label}`).toEqual({ status: 200, json: { ok: true, page: { entries: [
        { canonical_bytes: canonical(seed.logId, seed.entryIds[0]!, seed.writerId, 1, null), writer_seq: 1 },
        { canonical_bytes: canonical(seed.logId, seed.entryIds[1]!, seed.writerId, 2, seed.entryIds[0]!), writer_seq: 2 },
      ], next_after_seq: null } } });

      const tail = await gateway(seed.realm, "/tail-local", secret, { log_id: seed.logId, after_arrival: 0, limit: 10 });
      expect(tail, `tail-local ${label}`).toMatchObject({ status: 200, json: { ok: true, page: { next_after_arrival: null } } });
      expect(tail.json!.page.entries.map((entry: Json) => entry.canonical_bytes)).toEqual([
        canonical(seed.logId, seed.entryIds[0]!, seed.writerId, 1, null),
        canonical(seed.logId, seed.entryIds[1]!, seed.writerId, 2, seed.entryIds[0]!),
      ]);

      const ids = await gateway(seed.realm, "/list-log-ids", secret, {});
      expect(ids, `list-log-ids ${label}`).toEqual({ status: 200, json: { ok: true, log_ids: [seed.logId], next_after_log_id: null } });

      const inventory = await gateway(seed.realm, "/list-logs", secret, { max_logs: 64 });
      expect(inventory, `list-logs ${label}`).toMatchObject({ status: 200, json: { ok: true, result: {
        generation: expect.any(String),
        logs: [{ log_id: seed.logId, format_version: 1, revision: 2, document_writer_id: seed.writerId,
          writers: [{ writer_id: seed.writerId, last_seq: 2, last_entry_id: seed.entryIds[1] }] }],
      } } });
    }

    // ⛔ A READ ROUTE STAYS A READ: not one catalog object and not one row changed.
    expect(await inRealm(seed.realm, catalog)).toEqual(catalogBefore);
    expect(await inRealm(seed.realm, rows)).toEqual(rowsBefore);
  });

  it("the Container storage lane (storageFetch, no bearer) reads the legacy realm and writes nothing", async () => {
    const seed = await seedLegacyRealm(true);
    const catalogBefore = await inRealm(seed.realm, catalog);
    const storage = async (path: string, body: unknown) =>
      await runInDurableObject(env.REALM_CONTAINER.getByName(seed.realm), async (instance) => {
        const response = await instance.storageFetch(new Request(`https://realm-node.internal${path}`, {
          method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
        }));
        return { status: response.status, json: await response.json() as Json };
      });
    expect(await storage("/frontier", { log_id: seed.logId })).toEqual({ status: 200, json: { ok: true, frontier: { writers: [
      { writer_id: seed.writerId, seq: 2, entry_id: seed.entryIds[1] },
    ] } } });
    expect(await storage("/read-writer", { log_id: seed.logId, writer_id: seed.writerId, after_seq: 1, limit: 10 }))
      .toEqual({ status: 200, json: { ok: true, page: { entries: [
        { canonical_bytes: canonical(seed.logId, seed.entryIds[1]!, seed.writerId, 2, seed.entryIds[0]!), writer_seq: 2 },
      ], next_after_seq: null } } });
    expect((await storage("/list-logs", { max_logs: 64 })).status).toBe(200);
    expect(await inRealm(seed.realm, catalog)).toEqual(catalogBefore);
  });

  it("the ordinary WRITE routes, read-capability rotation and removal work on the legacy realm", async () => {
    const seed = await seedLegacyRealm(true);
    const before = await inRealm(seed.realm, rows);

    const lease = await gateway(seed.realm, "/take-lease", seed.writeSecret, { log_id: seed.logId });
    expect(lease).toEqual({ status: 200, json: { ok: true, lease_epoch: 2, writer_id: seed.writerId } });
    const third = crypto.randomUUID();
    const commit = await gateway(seed.realm, "/commit", seed.writeSecret, {
      log_id: seed.logId, expected_revision: 2, expected_epoch: 2,
      insert_entries: [{ entry_id: third, writer_id: seed.writerId, writer_seq: 3, prev_entry_id: seed.entryIds[1],
        created_at: "2026-09-13T21:00:00Z", canonical_bytes: canonical(seed.logId, third, seed.writerId, 3, seed.entryIds[1]!) }],
      put_tips: [{ writer_id: seed.writerId, last_seq: 3, last_entry_id: third }],
    });
    expect(commit).toEqual({ status: 200, json: { ok: true, revision: 3 } });
    expect((await gateway(seed.realm, "/frontier", seed.readSecret, { log_id: seed.logId })).json)
      .toEqual({ ok: true, frontier: { writers: [{ writer_id: seed.writerId, seq: 3, entry_id: third }] } });

    // ⭐ Take-lease and commit do not create restore tables either; only the restore-era writes below do.
    expect(await inRealm(seed.realm, tables)).toEqual(LEGACY_TABLES);
    const after = await inRealm(seed.realm, rows);
    expect(after.entries.slice(0, 2)).toEqual(before.entries);

    const second = crypto.randomUUID();
    expect(await gateway(seed.realm, "/create-log", seed.writeSecret, { log_id: second }))
      .toEqual({ status: 201, json: { ok: true } });
    // Pre-existing behaviour, recorded: `createLog` runs `initSchema`, which adds the restore tables.
    console.info("LEGACY tables after create-log", JSON.stringify(await inRealm(seed.realm, tables)));
    expect((await gateway(seed.realm, "/list-log-ids", seed.readSecret, {})).json!.log_ids)
      .toEqual([seed.logId, second].sort());
    expect((await gateway(seed.realm, "/frontier", seed.readSecret, { log_id: seed.logId })).json)
      .toEqual({ ok: true, frontier: { writers: [{ writer_id: seed.writerId, seq: 3, entry_id: third }] } });

    // Read capability: the one minted by 76f9028's create is still honoured, rotation works.
    expect(await gateway(seed.realm, "/realm/read-capability", seed.writeSecret, {}))
      .toEqual({ status: 409, json: { ok: false, error: { code: "read_capability_exists" } } });
    expect((await gateway(seed.realm, "/realm/read-capability", seed.writeSecret, null, "DELETE")).status).toBe(204);
    expect((await gateway(seed.realm, "/frontier", seed.readSecret, { log_id: seed.logId })).status).toBe(401);
    const minted = await gateway(seed.realm, "/realm/read-capability", seed.writeSecret, {});
    expect(minted).toMatchObject({ status: 201, json: { ok: true, read_secret: expect.stringMatching(/^[0-9a-f]{64}$/) } });
    expect((await gateway(seed.realm, "/frontier", String(minted.json!.read_secret), { log_id: seed.logId })).status).toBe(200);

    // Removal.
    const removed = await gateway(seed.realm, "", seed.writeSecret, null, "DELETE");
    expect(removed.status).toBe(204);
    expect(await inRealm(seed.realm, tables)).toEqual([]);
    expect(await gateway(seed.realm, "/frontier", seed.writeSecret, { log_id: seed.logId }))
      .toEqual({ status: 404, json: { ok: false, error: { code: "not_found" } } });
  });

  it("removal works on a legacy realm that never saw a current-code write", async () => {
    const seed = await seedLegacyRealm(true);
    expect((await gateway(seed.realm, "", seed.writeSecret, null, "DELETE")).status).toBe(204);
    expect(await inRealm(seed.realm, tables)).toEqual([]);
  });

  it("restore onto a legacy realm with logs refuses by name; onto an empty legacy realm it imports", async () => {
    const bundle = (logId: string, writerId: string, entryId: string) => ({
      bundle_id: `bundle-${logId}`,
      max_logs: 1,
      logs: [{ log_id: logId, archive_id: `archive-${logId}`, writer_id: writerId,
        entries: [canonical(logId, entryId, writerId, 1, null)] }],
    });

    const populated = await seedLegacyRealm(true);
    const rowsBefore = await inRealm(populated.realm, rows);
    const log = crypto.randomUUID();
    const refused = await gateway(populated.realm, "/restore-bundle-batch", populated.writeSecret,
      bundle(log, crypto.randomUUID(), crypto.randomUUID()));
    console.info("LEGACY restore onto populated", refused.status, JSON.stringify(refused.json),
      "tables", JSON.stringify(await inRealm(populated.realm, tables)));
    expect(refused).toEqual({ status: 409, json: { ok: false, error: { code: "constraint" } } });
    expect(await inRealm(populated.realm, rows)).toEqual(rowsBefore);
    // The prior log still reads after the refusal.
    expect((await gateway(populated.realm, "/frontier", populated.readSecret, { log_id: populated.logId })).status).toBe(200);

    const empty = await seedLegacyRealm(false);
    expect(await inRealm(empty.realm, tables)).toEqual(["realm_meta"]);
    const emptyLog = crypto.randomUUID();
    const writer = crypto.randomUUID();
    const accepted = await gateway(empty.realm, "/restore-bundle-batch", empty.writeSecret,
      bundle(emptyLog, writer, crypto.randomUUID()));
    console.info("LEGACY restore onto empty", accepted.status, JSON.stringify(accepted.json));
    expect(accepted).toEqual({ status: 200, json: { ok: true, result: { imported_logs: 1, skipped_logs: 0, complete: true } } });
    expect((await gateway(empty.realm, "/frontier", empty.readSecret, { log_id: emptyLog })).status).toBe(200);
  });

  it("allocation over an existing legacy realm refuses by name and leaves the realm unchanged", async () => {
    const seed = await seedLegacyRealm(true);
    const catalogBefore = await inRealm(seed.realm, catalog);
    const rowsBefore = await inRealm(seed.realm, rows);
    const secret = Array.from(crypto.getRandomValues(new Uint8Array(32)), (b) => b.toString(16).padStart(2, "0")).join("");
    const allocated = await gateway(seed.realm, "/allocate", "test-gateway-token", {
      operation_id: crypto.randomUUID(), realm_secret: secret,
    });
    console.info("LEGACY allocate over existing", allocated.status, JSON.stringify(allocated.json),
      "tables", JSON.stringify(await inRealm(seed.realm, tables)));
    expect(allocated).toEqual({ status: 409, json: { ok: false, error: { code: "allocation_conflict" } } });
    expect(await inRealm(seed.realm, catalog)).toEqual(catalogBefore);
    expect(await inRealm(seed.realm, rows)).toEqual(rowsBefore);
    expect((await gateway(seed.realm, "/frontier", seed.writeSecret, { log_id: seed.logId })).status).toBe(200);
  });
});
