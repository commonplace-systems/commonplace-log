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
 * LOG-REALM-HARDEN-2/3. Commit invariants (bytes↔columns agreement, writer_seq >= 1,
 * non-regressing tips), /create-log log_id and format_version validation, the raw-body cap,
 * limit clamps, and /read-set array bounds.
 *
 * ⭐ EVERY REFUSAL RUNS AGAINST BOTH REALM FLAVOURS — one whose SQLite schema was built by the
 * byte-pinned `76f9028` code (the 2026-09-13 outage shape) and one built by current code through
 * the gateway — using EXACTLY the request paths the app forwards (/create-log /take-lease
 * /read-set /commit /frontier /read-writer /tail-local). Every refusal test carries a VALID
 * NEIGHBOUR arm: the nearest legitimate request still succeeds.
 */

type Json = Record<string, any>;

// Pinned wire contracts (changing a value here is a wire contract change):
const MAX_RAW_BODY_BYTES = 8 * 1024 * 1024;
const MAX_PAGE_LIMIT = 1000;
const MAX_READ_SET_WRITERS = 99;
const MAX_READ_SET_COORDINATES = 49;
const MAX_READ_SET_ENTRY_IDS = 99;
const MAX_LOG_ID_BYTES = 256;

const CREATED_AT = "2026-09-05T15:30:00Z";

interface SeededRealm {
  realm: string;
  secret: string;
  logId: string;
  writerId: string;
  entryIds: string[];
  /** log revision after the two seeded entries */
  revision: number;
  epoch: number;
}

function canonical(logId: string, entryId: string, writerId: string, seq: number, prev: string | null): string {
  return btoa(JSON.stringify({
    body: { n: seq },
    created_at: CREATED_AT,
    entry_id: entryId,
    log_id: logId,
    prev_entry_id: prev,
    version: 1,
    writer_id: writerId,
    writer_seq: seq,
  }));
}

function insertEntry(logId: string, entryId: string, writerId: string, seq: number, prev: string | null) {
  return {
    entry_id: entryId,
    writer_id: writerId,
    writer_seq: seq,
    prev_entry_id: prev,
    created_at: CREATED_AT,
    canonical_bytes: canonical(logId, entryId, writerId, seq, prev),
  };
}

async function gateway(realm: string, path: string, bearer: string | null, body: unknown, method = "POST") {
  return await gatewayRaw(realm, path, bearer, body === undefined ? undefined : JSON.stringify(body), method);
}

async function gatewayRaw(realm: string, path: string, bearer: string | null, rawBody: string | undefined, method = "POST") {
  const headers = new Headers({ "content-type": "application/json" });
  if (bearer !== null) headers.set("authorization", `Bearer ${bearer}`);
  const response = await SELF.fetch(`https://gateway.invalid/realms/${realm}${path}`, {
    method,
    headers,
    body: rawBody,
  });
  const text = await response.text();
  let json: Json | null = null;
  try { json = text.length === 0 ? null : JSON.parse(text) as Json; } catch { json = { raw: text }; }
  return { status: response.status, json };
}

/** Create a realm and a two-entry log entirely through the byte-pinned `76f9028` code. */
async function seedLegacyRealm(): Promise<SeededRealm> {
  const realm = crypto.randomUUID();
  const logId = crypto.randomUUID();
  return await runInDurableObject(env.REALM_CONTAINER.getByName(realm), async (_instance, state) => {
    const auth = new LegacyRealmAuth(state.storage.sql, state.storage);
    const store = new LegacyRealmStore(state.storage.sql, state.storage);
    const registry: LegacyRegistry & { capability: string | null } = {
      capability: null,
      async put(_realm, readCapability) { this.capability = readCapability; },
      async delete() { this.capability = null; },
    };
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
    const secret = String(created.json.realm_secret);

    const bearer = { authorization: `Bearer ${secret}` };
    expect(await call("/create-log", { log_id: logId, format_version: 1, created_at: CREATED_AT }, bearer))
      .toEqual({ status: 201, json: { ok: true } });
    const lease = await call("/take-lease", { log_id: logId }, bearer);
    expect(lease).toMatchObject({ status: 200, json: { ok: true, lease_epoch: 1 } });
    const writerId = String(lease.json.writer_id);
    const entryIds = [crypto.randomUUID(), crypto.randomUUID()];
    let prev: string | null = null;
    for (const [index, entryId] of entryIds.entries()) {
      const committed = await call("/commit", {
        log_id: logId,
        expected_revision: index,
        expected_epoch: 1,
        insert_entries: [insertEntry(logId, entryId, writerId, index + 1, prev)],
        put_tips: [{ writer_id: writerId, last_seq: index + 1, last_entry_id: entryId }],
      }, bearer);
      expect(committed).toEqual({ status: 200, json: { ok: true, revision: index + 1 } });
      prev = entryId;
    }
    return { realm, secret, logId, writerId, entryIds, revision: 2, epoch: 1 };
  });
}

/** Create a realm and a two-entry log through the gateway on current code — the app's shapes. */
async function seedCurrentRealm(): Promise<SeededRealm> {
  const realm = crypto.randomUUID();
  const logId = crypto.randomUUID();
  const created = await gateway(realm, "", env.GATEWAY_TOKEN, {});
  expect(created).toMatchObject({ status: 201, json: { ok: true, registry: "registered" } });
  const secret = String(created.json!.realm_secret);

  expect(await gateway(realm, "/create-log", secret, { log_id: logId, format_version: 1, created_at: CREATED_AT }))
    .toEqual({ status: 201, json: { ok: true } });
  const lease = await gateway(realm, "/take-lease", secret, { log_id: logId });
  expect(lease).toMatchObject({ status: 200, json: { ok: true, lease_epoch: 1 } });
  const writerId = String(lease.json!.writer_id);
  const entryIds = [crypto.randomUUID(), crypto.randomUUID()];
  let prev: string | null = null;
  for (const [index, entryId] of entryIds.entries()) {
    const committed = await gateway(realm, "/commit", secret, {
      log_id: logId,
      expected_revision: index,
      expected_epoch: 1,
      insert_entries: [insertEntry(logId, entryId, writerId, index + 1, prev)],
      put_tips: [{ writer_id: writerId, last_seq: index + 1, last_entry_id: entryId }],
    });
    expect(committed).toEqual({ status: 200, json: { ok: true, revision: index + 1 } });
    prev = entryId;
  }
  return { realm, secret, logId, writerId, entryIds, revision: 2, epoch: 1 };
}

async function frontierSeq(seed: SeededRealm): Promise<Json> {
  const response = await gateway(seed.realm, "/frontier", seed.secret, { log_id: seed.logId });
  expect(response.status).toBe(200);
  return response.json!.frontier;
}

const flavours: Array<[string, () => Promise<SeededRealm>]> = [
  ["legacy-76f9028 realm", seedLegacyRealm],
  ["current-code realm", seedCurrentRealm],
];

describe.each(flavours)("realm hardening on a %s", (_name, seedRealm) => {
  it("commit refuses entries whose canonical bytes disagree with their columns; agreeing bytes commit", async () => {
    const seed = await seedRealm();
    const next = crypto.randomUUID();
    const base = () => ({
      log_id: seed.logId,
      expected_revision: seed.revision,
      expected_epoch: seed.epoch,
      insert_entries: [insertEntry(seed.logId, next, seed.writerId, 3, seed.entryIds[1]!)],
      put_tips: [{ writer_id: seed.writerId, last_seq: 3, last_entry_id: next }],
    });

    // entry_id column disagrees with the bytes.
    const wrongId = base();
    wrongId.insert_entries[0]!.canonical_bytes = canonical(seed.logId, crypto.randomUUID(), seed.writerId, 3, seed.entryIds[1]!);
    expect(await gateway(seed.realm, "/commit", seed.secret, wrongId))
      .toEqual({ status: 409, json: { ok: false, error: { code: "entry_bytes_mismatch" } } });

    // writer_seq column disagrees with the bytes.
    const wrongSeq = base();
    wrongSeq.insert_entries[0]!.canonical_bytes = canonical(seed.logId, next, seed.writerId, 9, seed.entryIds[1]!);
    expect(await gateway(seed.realm, "/commit", seed.secret, wrongSeq))
      .toEqual({ status: 409, json: { ok: false, error: { code: "entry_bytes_mismatch" } } });

    // writer_id column disagrees with the bytes.
    const wrongWriter = base();
    wrongWriter.insert_entries[0]!.canonical_bytes = canonical(seed.logId, next, "someone-else", 3, seed.entryIds[1]!);
    expect(await gateway(seed.realm, "/commit", seed.secret, wrongWriter))
      .toEqual({ status: 409, json: { ok: false, error: { code: "entry_bytes_mismatch" } } });

    // Bytes that are not a JSON object at all.
    const notJson = base();
    notJson.insert_entries[0]!.canonical_bytes = btoa("not json at all");
    expect(await gateway(seed.realm, "/commit", seed.secret, notJson))
      .toEqual({ status: 409, json: { ok: false, error: { code: "entry_bytes_mismatch" } } });

    // Nothing was written by any refusal.
    expect(await frontierSeq(seed)).toEqual({ writers: [{ writer_id: seed.writerId, seq: 2, entry_id: seed.entryIds[1] }] });

    // ⭐ VALID NEIGHBOUR: the same commit with agreeing bytes succeeds.
    expect(await gateway(seed.realm, "/commit", seed.secret, base()))
      .toEqual({ status: 200, json: { ok: true, revision: seed.revision + 1 } });
    expect(await frontierSeq(seed)).toEqual({ writers: [{ writer_id: seed.writerId, seq: 3, entry_id: next }] });
  });

  it("commit refuses writer_seq 0; a fresh writer's seq exactly 1 commits", async () => {
    const seed = await seedRealm();
    const zeroId = crypto.randomUUID();
    // Bytes and columns AGREE at writer_seq 0, isolating the sequence gate from the agreement gate.
    expect(await gateway(seed.realm, "/commit", seed.secret, {
      log_id: seed.logId,
      expected_revision: seed.revision,
      expected_epoch: seed.epoch,
      insert_entries: [insertEntry(seed.logId, zeroId, "merge-writer", 0, null)],
      put_tips: [{ writer_id: "merge-writer", last_seq: 0, last_entry_id: zeroId }],
    })).toEqual({ status: 409, json: { ok: false, error: { code: "invalid_writer_seq" } } });
    expect(await frontierSeq(seed)).toEqual({ writers: [{ writer_id: seed.writerId, seq: 2, entry_id: seed.entryIds[1] }] });

    // ⭐ VALID NEIGHBOUR: seq exactly 1 for a fresh writer (the app's merge shape) succeeds.
    const firstId = crypto.randomUUID();
    expect(await gateway(seed.realm, "/commit", seed.secret, {
      log_id: seed.logId,
      expected_revision: seed.revision,
      expected_epoch: seed.epoch,
      insert_entries: [insertEntry(seed.logId, firstId, "merge-writer", 1, null)],
      put_tips: [{ writer_id: "merge-writer", last_seq: 1, last_entry_id: firstId }],
    })).toEqual({ status: 200, json: { ok: true, revision: seed.revision + 1 } });
    expect((await frontierSeq(seed)).writers).toContainEqual({ writer_id: "merge-writer", seq: 1, entry_id: firstId });
  });

  it("commit refuses a tip below the stored tip; a tip equal to the stored tip succeeds", async () => {
    const seed = await seedRealm();
    expect(await gateway(seed.realm, "/commit", seed.secret, {
      log_id: seed.logId,
      expected_revision: seed.revision,
      expected_epoch: seed.epoch,
      insert_entries: [],
      put_tips: [{ writer_id: seed.writerId, last_seq: 1, last_entry_id: seed.entryIds[0] }],
    })).toEqual({ status: 409, json: { ok: false, error: { code: "tip_regression" } } });
    expect(await frontierSeq(seed)).toEqual({ writers: [{ writer_id: seed.writerId, seq: 2, entry_id: seed.entryIds[1] }] });

    // ⭐ VALID NEIGHBOUR: re-putting the tip EQUAL to the stored tip is legitimate (an
    // already-present merge re-asserts the tip it read) and succeeds.
    expect(await gateway(seed.realm, "/commit", seed.secret, {
      log_id: seed.logId,
      expected_revision: seed.revision,
      expected_epoch: seed.epoch,
      insert_entries: [],
      put_tips: [{ writer_id: seed.writerId, last_seq: 2, last_entry_id: seed.entryIds[1] }],
    })).toEqual({ status: 200, json: { ok: true, revision: seed.revision + 1 } });
    expect(await frontierSeq(seed)).toEqual({ writers: [{ writer_id: seed.writerId, seq: 2, entry_id: seed.entryIds[1] }] });
  });

  it("create-log refuses the empty and oversize log_id; a 256-byte log_id still creates", async () => {
    const seed = await seedRealm();
    expect(await gateway(seed.realm, "/create-log", seed.secret, { log_id: "" }))
      .toEqual({ status: 400, json: { ok: false, error: { code: "invalid_log_id" } } });
    expect(await gateway(seed.realm, "/create-log", seed.secret, { log_id: "x".repeat(MAX_LOG_ID_BYTES + 1) }))
      .toEqual({ status: 400, json: { ok: false, error: { code: "invalid_log_id" } } });
    // The bound is measured in BYTES, as in the restore wire: 129 two-byte characters is 258 bytes.
    expect(await gateway(seed.realm, "/create-log", seed.secret, { log_id: "é".repeat(129) }))
      .toEqual({ status: 400, json: { ok: false, error: { code: "invalid_log_id" } } });
    // None of the refusals created a log.
    expect((await gateway(seed.realm, "/list-log-ids", seed.secret, {})).json!.log_ids).toEqual([seed.logId]);

    // ⭐ VALID NEIGHBOUR: exactly 256 bytes still creates and is readable.
    const atCap = "x".repeat(MAX_LOG_ID_BYTES);
    expect(await gateway(seed.realm, "/create-log", seed.secret, { log_id: atCap }))
      .toEqual({ status: 201, json: { ok: true } });
    expect(await gateway(seed.realm, "/frontier", seed.secret, { log_id: atCap }))
      .toEqual({ status: 200, json: { ok: true, frontier: { writers: [] } } });
  });

  it("create-log refuses format_version other than 1; format_version 1 and absent still create", async () => {
    const seed = await seedRealm();
    for (const formatVersion of [0, 2]) {
      expect(await gateway(seed.realm, "/create-log", seed.secret, { log_id: crypto.randomUUID(), format_version: formatVersion }))
        .toEqual({ status: 400, json: { ok: false, error: { code: "unsupported_format_version" } } });
    }
    expect((await gateway(seed.realm, "/list-log-ids", seed.secret, {})).json!.log_ids).toEqual([seed.logId]);

    // ⭐ VALID NEIGHBOURS: format_version exactly 1 (the app's shape) and format_version absent.
    const explicit = crypto.randomUUID();
    const defaulted = crypto.randomUUID();
    expect(await gateway(seed.realm, "/create-log", seed.secret, { log_id: explicit, format_version: 1 }))
      .toEqual({ status: 201, json: { ok: true } });
    expect(await gateway(seed.realm, "/create-log", seed.secret, { log_id: defaulted }))
      .toEqual({ status: 201, json: { ok: true } });
    expect(await gateway(seed.realm, "/frontier", seed.secret, { log_id: explicit }))
      .toEqual({ status: 200, json: { ok: true, frontier: { writers: [] } } });
  });

  it("a request body over the cap is refused 413; a body at exactly the cap is served", async () => {
    const seed = await seedRealm();
    const bare = JSON.stringify({ log_id: seed.logId });
    // JSON tolerates trailing whitespace, so padding reaches the exact byte boundary
    // without changing the request's meaning.
    const atCap = bare + " ".repeat(MAX_RAW_BODY_BYTES - bare.length);
    const overCap = atCap + " ";

    expect(await gatewayRaw(seed.realm, "/frontier", seed.secret, overCap))
      .toEqual({ status: 413, json: { ok: false, error: { code: "oversize" } } });

    // ⭐ VALID NEIGHBOUR: exactly at the cap the same request answers normally.
    expect(await gatewayRaw(seed.realm, "/frontier", seed.secret, atCap))
      .toEqual({ status: 200, json: { ok: true, frontier: { writers: [
        { writer_id: seed.writerId, seq: 2, entry_id: seed.entryIds[1] },
      ] } } });
  });

  it("read-writer and tail-local clamp an oversized limit instead of refusing it", async () => {
    const seed = await seedRealm();
    // The engine's document lane sends limit = tip_seq, which is unbounded; a refusal here
    // would be an outage, so an over-cap limit must still answer 200 with the page clamped.
    const readWriter = await gateway(seed.realm, "/read-writer", seed.secret, {
      log_id: seed.logId, writer_id: seed.writerId, after_seq: 0, limit: 5000,
    });
    expect(readWriter.status).toBe(200);
    expect(readWriter.json!.page.entries.map((entry: Json) => entry.writer_seq)).toEqual([1, 2]);
    expect(readWriter.json!.page.next_after_seq).toBeNull();

    const tail = await gateway(seed.realm, "/tail-local", seed.secret, {
      log_id: seed.logId, after_arrival: 0, limit: 5000,
    });
    expect(tail.status).toBe(200);
    expect(tail.json!.page.entries).toHaveLength(2);
    expect(tail.json!.page.next_after_arrival).toBeNull();
  });

  it("read-set arrays above the placeholder bound are refused 413; arrays at the bound answer", async () => {
    const seed = await seedRealm();
    const filler = (count: number, prefix: string) => Array.from({ length: count }, (_, n) => `${prefix}-${n}`);

    expect(await gateway(seed.realm, "/read-set", seed.secret, {
      log_id: seed.logId,
      writers: [seed.writerId, ...filler(MAX_READ_SET_WRITERS, "w")],
      coordinates: [],
      entry_ids: [],
    })).toEqual({ status: 413, json: { ok: false, error: { code: "oversize" } } });

    expect(await gateway(seed.realm, "/read-set", seed.secret, {
      log_id: seed.logId,
      writers: [],
      coordinates: [
        { writer_id: seed.writerId, writer_seq: 1 },
        ...filler(MAX_READ_SET_COORDINATES, "c").map((writerId, n) => ({ writer_id: writerId, writer_seq: n + 1 })),
      ],
      entry_ids: [],
    })).toEqual({ status: 413, json: { ok: false, error: { code: "oversize" } } });

    expect(await gateway(seed.realm, "/read-set", seed.secret, {
      log_id: seed.logId,
      writers: [],
      coordinates: [],
      entry_ids: [seed.entryIds[0], ...filler(MAX_READ_SET_ENTRY_IDS, "e")],
    })).toEqual({ status: 413, json: { ok: false, error: { code: "oversize" } } });

    // ⭐ VALID NEIGHBOUR: every array at exactly its bound, containing the real rows, answers.
    const atBound = await gateway(seed.realm, "/read-set", seed.secret, {
      log_id: seed.logId,
      writers: [seed.writerId, ...filler(MAX_READ_SET_WRITERS - 1, "w")],
      coordinates: [
        { writer_id: seed.writerId, writer_seq: 1 },
        ...filler(MAX_READ_SET_COORDINATES - 1, "c").map((writerId, n) => ({ writer_id: writerId, writer_seq: n + 1 })),
      ],
      entry_ids: [seed.entryIds[1], ...filler(MAX_READ_SET_ENTRY_IDS - 1, "e")],
    });
    expect(atBound.status).toBe(200);
    expect(atBound.json!.read_set.tips).toEqual([
      { writer_id: seed.writerId, last_seq: 2, last_entry_id: seed.entryIds[1] },
    ]);
    expect(atBound.json!.read_set.coordinates).toEqual([
      { writer_id: seed.writerId, writer_seq: 1, canonical_bytes: canonical(seed.logId, seed.entryIds[0]!, seed.writerId, 1, null) },
    ]);
    expect(atBound.json!.read_set.entry_ids).toEqual([
      { entry_id: seed.entryIds[1], canonical_bytes: canonical(seed.logId, seed.entryIds[1]!, seed.writerId, 2, seed.entryIds[0]!) },
    ]);
  });
});

describe("limit clamp actually clamps at 1000", () => {
  it("a writer with 1001 entries pages at exactly 1000 for read-writer and tail-local", async () => {
    const seed = await seedCurrentRealm();
    const bulkLog = crypto.randomUUID();
    expect((await gateway(seed.realm, "/create-log", seed.secret, { log_id: bulkLog })).status).toBe(201);

    const total = MAX_PAGE_LIMIT + 1;
    const ids = Array.from({ length: total }, (_, n) => `bulk-entry-${n + 1}`);
    const entries = ids.map((entryId, index) =>
      insertEntry(bulkLog, entryId, "bulk-writer", index + 1, index === 0 ? null : ids[index - 1]!));
    expect(await gateway(seed.realm, "/commit", seed.secret, {
      log_id: bulkLog,
      expected_revision: 0,
      expected_epoch: 0,
      insert_entries: entries,
      put_tips: [{ writer_id: "bulk-writer", last_seq: total, last_entry_id: ids[total - 1] }],
    })).toEqual({ status: 200, json: { ok: true, revision: 1 } });

    const first = await gateway(seed.realm, "/read-writer", seed.secret, {
      log_id: bulkLog, writer_id: "bulk-writer", after_seq: 0, limit: total,
    });
    expect(first.status).toBe(200);
    expect(first.json!.page.entries).toHaveLength(MAX_PAGE_LIMIT);
    expect(first.json!.page.next_after_seq).toBe(MAX_PAGE_LIMIT);
    const rest = await gateway(seed.realm, "/read-writer", seed.secret, {
      log_id: bulkLog, writer_id: "bulk-writer", after_seq: MAX_PAGE_LIMIT, limit: total,
    });
    expect(rest.json!.page.entries).toHaveLength(1);
    expect(rest.json!.page.next_after_seq).toBeNull();

    const tail = await gateway(seed.realm, "/tail-local", seed.secret, {
      log_id: bulkLog, after_arrival: 0, limit: total,
    });
    expect(tail.status).toBe(200);
    expect(tail.json!.page.entries).toHaveLength(MAX_PAGE_LIMIT);
    expect(tail.json!.page.next_after_arrival).not.toBeNull();
  });
});
