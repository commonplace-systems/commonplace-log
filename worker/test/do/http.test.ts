import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import { handleRequest } from "../../src/do/http";
import { LogStore } from "../../src/do/store";
import { canonicalize } from "../../src/jcs";
import { uuidv7 } from "../../src/do/uuid";

/**
 * SP2 Task 7: the §11 HTTP protocol surface, exercised against a real
 * LogStore over real DO SQLite storage. Every reachable §11.6 error is
 * asserted with BOTH its status and its envelope; success shapes are
 * asserted field-by-field in snake_case wire form.
 *
 * HARNESS CONSTRAINT (discovered empirically, probe recorded in the Task 7
 * notes): under @cloudflare/vitest-pool-workers, ctx.id.name is ALWAYS
 * undefined inside the object — the integration re-addresses Durable
 * Objects by derived unique ids to isolate per-test storage, so a name
 * given to idFromName never reaches the instance, and every request through
 * the real CommonplaceLog.fetch is 409-rejected by the §13.1 name check.
 * Therefore: route behavior is driven through handleRequest with the
 * objectName injected (real store, real SQLite, real transactions via
 * runInDurableObject's state), while the DO-class wiring itself is proved by
 * the fetch-level tests at the bottom, whose §13.1 rejection is genuine
 * production behavior for an object addressed without a name.
 *
 * Anti-vacuity: this file registers 39 tests (>= the 20-test floor).
 */

const LOG_ID = "0198cc6e-47ac-7d72-93db-b6fbd92bfca2";
const OTHER_LOG_ID = "0198cc6e-47ac-7d72-93db-b6fbd92bfca3";
const WRITER_A = "0b7bc7de-92ee-4d63-9d1c-8b7f0f3a2c11";
const WRITER_B = "fab4e8a5-ce9e-48d0-8f78-1d312b978207";
const CREATED_AT = "2026-08-22T12:00:00Z";

type RawEntry = Record<string, unknown>;

/** A Response flattened to structured-clonable data: a Response object must
 * not cross the runInDurableObject boundary (isolated storage fails to pop
 * its stack frame when one does — observed directly on this suite). */
interface Wire {
  status: number;
  contentType: string | null;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  body: any;
}

function namedStub() {
  return env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName(LOG_ID));
}

/**
 * Drive one §11 request through handleRequest with a real LogStore over the
 * test's real DO SQLite storage. `objectName` mimics what production
 * ctx.id.name would be for a log DO addressed via idFromName.
 */
async function callWithName(
  objectName: string | undefined,
  method: string,
  path: string,
  reqBody?: unknown,
): Promise<Wire> {
  return await runInDurableObject(namedStub(), async (_instance, state) => {
    const init: RequestInit = { method };
    if (reqBody !== undefined) {
      init.body = typeof reqBody === "string" ? reqBody : JSON.stringify(reqBody);
    }
    const store = new LogStore(state.storage.sql, state.storage);
    const res = await handleRequest(new Request(`https://do${path}`, init), {
      store,
      objectName,
    });
    return {
      status: res.status,
      contentType: res.headers.get("content-type"),
      body: await res.json(),
    };
  });
}

/** The common case: the object is named exactly by the log_id (§13.1, SP2). */
async function call(method: string, path: string, reqBody?: unknown): Promise<Wire> {
  return await callWithName(LOG_ID, method, path, reqBody);
}

async function createLog(): Promise<void> {
  const res = await call("PUT", `/v1/logs/${LOG_ID}`, { version: 1 });
  if (res.status !== 200) throw new Error(`createLog failed: ${res.status}`);
}

/** n chained entries for a writer, continuing after (lastSeq, lastEntryId). */
function extendChain(
  writerId: string,
  n: number,
  lastSeq: number,
  lastEntryId: string | null,
  bodyFor: (seq: number) => Record<string, unknown> = (seq) => ({ seq }),
): RawEntry[] {
  const entries: RawEntry[] = [];
  let prev = lastEntryId;
  for (let i = 1; i <= n; i++) {
    const seq = lastSeq + i;
    const entryId = uuidv7();
    entries.push({
      version: 1,
      log_id: LOG_ID,
      entry_id: entryId,
      writer_id: writerId,
      writer_seq: seq,
      prev_entry_id: prev,
      created_at: CREATED_AT,
      body: bodyFor(seq),
    });
    prev = entryId;
  }
  return entries;
}

function chain(
  writerId: string,
  n: number,
  bodyFor?: (seq: number) => Record<string, unknown>,
): RawEntry[] {
  return extendChain(writerId, n, 0, null, bodyFor);
}

interface WireError {
  code: string;
  message: string;
  details?: Record<string, unknown>;
}

function expectError(res: Wire, status: number, code: string): WireError {
  expect(res.status).toBe(status);
  expect(res.contentType).toBe("application/json");
  const error = res.body.error as WireError;
  expect(error.code).toBe(code);
  expect(typeof error.message).toBe("string");
  return error;
}

describe("PUT /v1/logs/{log_id} (§11.1)", () => {
  it("returns 200 with application/json on first create", async () => {
    const res = await call("PUT", `/v1/logs/${LOG_ID}`, { version: 1 });
    expect(res.status).toBe(200);
    expect(res.contentType).toBe("application/json");
    expect(res.body).toEqual({ ok: true });
  });

  it("returns 200 again when the log already exists (idempotent)", async () => {
    await createLog();
    const res = await call("PUT", `/v1/logs/${LOG_ID}`, { version: 1 });
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ ok: true });
  });

  it("malformed JSON body -> 400 invalid_json", async () => {
    const res = await call("PUT", `/v1/logs/${LOG_ID}`, "{not json");
    expectError(res, 400, "invalid_json");
  });

  it("body without version 1 -> 422 invalid_entry with a reason detail", async () => {
    const res = await call("PUT", `/v1/logs/${LOG_ID}`, { version: 2 });
    const error = expectError(res, 422, "invalid_entry");
    expect(String(error.details?.["reason"])).toContain("version");
  });
});

describe("DO name <-> log_id verification (§13.1)", () => {
  it("path log_id differing from the object name -> 409 log_mismatch with both names in details", async () => {
    const res = await callWithName(LOG_ID, "GET", `/v1/logs/${OTHER_LOG_ID}/frontier`);
    const error = expectError(res, 409, "log_mismatch");
    expect(error.details).toMatchObject({
      object_name: LOG_ID,
      log_id: OTHER_LOG_ID,
    });
  });

  it("objectName === undefined -> 409 log_mismatch naming the unverifiable object, never a `undefined !== log_id` fall-through", async () => {
    const res = await callWithName(undefined, "PUT", `/v1/logs/${LOG_ID}`, { version: 1 });
    const error = expectError(res, 409, "log_mismatch");
    expect(String(error.details?.["reason"])).toContain("no name");
    expect(String(error.details?.["reason"])).toContain(LOG_ID);
    // Specifically NOT the named-mismatch shape carrying object_name: undefined.
    expect(Object.hasOwn(error.details ?? {}, "object_name")).toBe(false);
  });
});

describe("POST /v1/logs/{log_id}/entries (§11.2)", () => {
  it("before create -> 404 log_not_found", async () => {
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: chain(WRITER_A, 1),
    });
    expectError(res, 404, "log_not_found");
  });

  it("fresh 3-entry batch -> 200 {inserted:3, present:0, frontier.writers} in snake_case", async () => {
    await createLog();
    const entries = chain(WRITER_A, 3);
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries });
    expect(res.status).toBe(200);
    expect(res.contentType).toBe("application/json");
    expect(res.body).toEqual({
      inserted: 3,
      present: 0,
      frontier: {
        writers: [
          { writer_id: WRITER_A, seq: 3, entry_id: entries[2]!["entry_id"] },
        ],
      },
    });
  });

  it("re-POSTing the identical batch -> {inserted:0, present:3} (idempotent, §15.1)", async () => {
    await createLog();
    const entries = chain(WRITER_A, 3);
    await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries });
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries });
    expect(res.status).toBe(200);
    expect(res.body.inserted).toBe(0);
    expect(res.body.present).toBe(3);
  });

  it("response frontier lists ALL writers sorted by writer_id, not just the batch's", async () => {
    await createLog();
    const b = chain(WRITER_B, 2);
    await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: b });
    const a = chain(WRITER_A, 1);
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: a });
    // WRITER_A ("0b...") sorts before WRITER_B ("fa...").
    expect(res.body.frontier.writers).toEqual([
      { writer_id: WRITER_A, seq: 1, entry_id: a[0]!["entry_id"] },
      { writer_id: WRITER_B, seq: 2, entry_id: b[1]!["entry_id"] },
    ]);
  });

  it("malformed JSON body -> 400 invalid_json", async () => {
    await createLog();
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, '{"entries":[');
    expectError(res, 400, "invalid_json");
  });

  it("valid JSON but not an {entries:[...]} batch -> 422 invalid_entry", async () => {
    await createLog();
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: "nope" });
    const error = expectError(res, 422, "invalid_entry");
    expect(String(error.details?.["reason"])).toContain("entries");
  });

  it("101 entries -> 413 batch_too_large (default limit 100)", async () => {
    await createLog();
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: chain(WRITER_A, 101),
    });
    const error = expectError(res, 413, "batch_too_large");
    expect(error.details).toMatchObject({ entry_count: 101, max_entries: 100 });
  });

  it("oversized raw body is rejected 413 batch_too_large BEFORE parsing (§16: garbage body never reaches invalid_json)", async () => {
    await createLog();
    // NOT JSON: if the size gate ran after parsing, this would be 400
    // invalid_json. 413 batch_too_large proves the raw gate fired first.
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, "x".repeat(4_800_000));
    const error = expectError(res, 413, "batch_too_large");
    expect(error.details).toMatchObject({ max_raw_bytes: 4_718_592 });
  });

  it("canonical entry bytes totalling over 4 MiB -> 413 batch_too_large (exact post-validation measure)", async () => {
    await createLog();
    // 5 valid chained entries of ~0.85 MiB each: ~4.25 MiB canonical (over
    // the 4 MiB batch limit) but under the ~4.5 MiB raw pre-parse gate, so
    // ONLY the exact canonical measure can reject it.
    const entries = chain(WRITER_A, 5, () => ({ pad: "x".repeat(891_289) }));
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries });
    const error = expectError(res, 413, "batch_too_large");
    expect(error.details).toMatchObject({ max_canonical_bytes: 4_194_304 });
  });

  it("a single entry of exactly 1 MiB canonical bytes MUST work (§11.2)", async () => {
    await createLog();
    const [probe] = chain(WRITER_A, 1, () => ({ pad: "" }));
    const padLen = 1_048_576 - canonicalize(probe).byteLength;
    const entry = { ...probe!, body: { pad: "x".repeat(padLen) } };
    expect(canonicalize(entry).byteLength).toBe(1_048_576);
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: [entry] });
    expect(res.status).toBe(200);
    expect(res.body.inserted).toBe(1);
  });

  it("a single entry over 1 MiB -> 413 entry_too_large with SP1's slug in details", async () => {
    await createLog();
    const entries = chain(WRITER_A, 1, () => ({ pad: "x".repeat(1_048_576) }));
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries });
    const error = expectError(res, 413, "entry_too_large");
    expect(error.details).toMatchObject({ reason: "canonical-bytes-over-1mib" });
  });

  it("invalid entry (non-object body) -> 422 invalid_entry with SP1's slug in details", async () => {
    await createLog();
    const [entry] = chain(WRITER_A, 1);
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: [{ ...entry!, body: "not an object" }],
    });
    const error = expectError(res, 422, "invalid_entry");
    expect(error.details).toMatchObject({ reason: "body-not-object" });
  });

  it("batch starting past the tip -> 409 writer_gap with snake_case details and the spec's message form", async () => {
    await createLog();
    const [, e2] = chain(WRITER_A, 2);
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: [e2] });
    const error = expectError(res, 409, "writer_gap");
    expect(error.message).toBe("expected writer sequence 1");
    expect(error.details).toEqual({
      writer_id: WRITER_A,
      expected_seq: 1,
      tip_entry_id: null,
    });
  });

  it("a different entry at an occupied coordinate -> 409 writer_fork with snake_case details", async () => {
    await createLog();
    await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: chain(WRITER_A, 1) });
    const [rival] = chain(WRITER_A, 1); // fresh entry_id, same (writer, seq 1)
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: [rival] });
    const error = expectError(res, 409, "writer_fork");
    expect(error.details).toEqual({ writer_id: WRITER_A, seq: 1 });
  });

  it("reusing an entry_id for different bytes -> 409 entry_id_collision with snake_case details", async () => {
    await createLog();
    const [e1] = chain(WRITER_A, 1);
    await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: [e1] });
    const colliding = {
      ...extendChain(WRITER_A, 1, 1, String(e1!["entry_id"]))[0]!,
      entry_id: e1!["entry_id"],
    };
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: [colliding],
    });
    const error = expectError(res, 409, "entry_id_collision");
    expect(error.details).toEqual({ entry_id: e1!["entry_id"] });
  });

  it("intra-batch prev-linkage violation -> 422 invalid_entry (recorded invalid_batch mapping)", async () => {
    await createLog();
    const [e1, e2] = chain(WRITER_A, 2);
    const broken = { ...e2!, prev_entry_id: uuidv7() }; // does not name e1
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: [e1, broken],
    });
    const error = expectError(res, 422, "invalid_entry");
    expect(String(error.details?.["reason"])).toContain("prev_entry_id");
  });

  it("an entry whose log_id names another log -> 409 log_mismatch", async () => {
    await createLog();
    const [entry] = chain(WRITER_A, 1);
    const res = await call("POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: [{ ...entry!, log_id: OTHER_LOG_ID }],
    });
    const error = expectError(res, 409, "log_mismatch");
    expect(error.details).toMatchObject({
      entry_log_id: OTHER_LOG_ID,
      expected_log_id: LOG_ID,
    });
  });
});

describe("GET /v1/logs/{log_id}/frontier (§11.3)", () => {
  it("before create -> 404 log_not_found", async () => {
    const res = await call("GET", `/v1/logs/${LOG_ID}/frontier`);
    expectError(res, 404, "log_not_found");
  });

  it("returns the §9.4 encoded shape: log_id plus writers sorted by writer_id", async () => {
    await createLog();
    const b = chain(WRITER_B, 1);
    const a = chain(WRITER_A, 2);
    await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: [...b, ...a] });
    const res = await call("GET", `/v1/logs/${LOG_ID}/frontier`);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({
      log_id: LOG_ID,
      writers: [
        { writer_id: WRITER_A, seq: 2, entry_id: a[1]!["entry_id"] },
        { writer_id: WRITER_B, seq: 1, entry_id: b[0]!["entry_id"] },
      ],
    });
  });
});

describe("GET /v1/logs/{log_id}/writers/{writer_id}/entries (§11.4)", () => {
  it("pages through a writer with limit, returning canonical entry objects and next_after", async () => {
    await createLog();
    const entries = chain(WRITER_A, 5);
    await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries });

    const base = `/v1/logs/${LOG_ID}/writers/${WRITER_A}/entries`;
    const p1 = await call("GET", `${base}?limit=2`);
    expect(p1.status).toBe(200);
    expect(p1.body.entries).toEqual([entries[0], entries[1]]);
    expect(p1.body.next_after).toBe(2);

    const p2 = await call("GET", `${base}?after=${p1.body.next_after}&limit=2`);
    expect(p2.body.entries).toEqual([entries[2], entries[3]]);
    expect(p2.body.next_after).toBe(4);

    const p3 = await call("GET", `${base}?after=${p2.body.next_after}&limit=2`);
    expect(p3.body.entries).toEqual([entries[4]]);
    expect(p3.body.next_after).toBeNull();
  });

  it("honors after (exclusive) and through (inclusive)", async () => {
    await createLog();
    const entries = chain(WRITER_A, 5);
    await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries });
    const res = await call(
      "GET",
      `/v1/logs/${LOG_ID}/writers/${WRITER_A}/entries?after=1&through=3`,
    );
    expect(res.body.entries).toEqual([entries[1], entries[2]]);
    expect(res.body.next_after).toBeNull();
  });

  it("an unknown writer -> 200 with empty entries and null cursor (§10 sync probes)", async () => {
    await createLog();
    const res = await call("GET", `/v1/logs/${LOG_ID}/writers/${WRITER_B}/entries`);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ entries: [], next_after: null });
  });

  it("before create -> 404 log_not_found", async () => {
    const res = await call("GET", `/v1/logs/${LOG_ID}/writers/${WRITER_A}/entries`);
    expectError(res, 404, "log_not_found");
  });

  it("non-integer limit -> 422 invalid_entry with a reason detail", async () => {
    await createLog();
    const res = await call(
      "GET",
      `/v1/logs/${LOG_ID}/writers/${WRITER_A}/entries?limit=abc`,
    );
    const error = expectError(res, 422, "invalid_entry");
    expect(String(error.details?.["reason"])).toContain("limit");
  });

  it("negative after -> 422 invalid_entry (store RangeError mapped)", async () => {
    await createLog();
    const res = await call(
      "GET",
      `/v1/logs/${LOG_ID}/writers/${WRITER_A}/entries?after=-1`,
    );
    const error = expectError(res, 422, "invalid_entry");
    expect(String(error.details?.["reason"])).toContain("afterSeq");
  });

  it("limit=0 -> 422 invalid_entry (store RangeError mapped)", async () => {
    await createLog();
    const res = await call(
      "GET",
      `/v1/logs/${LOG_ID}/writers/${WRITER_A}/entries?limit=0`,
    );
    expectError(res, 422, "invalid_entry");
  });
});

describe("GET /v1/logs/{log_id}/entries (§11.5 arrival tail)", () => {
  it("returns entries in arrival order across writers with next_after_arrival paging", async () => {
    await createLog();
    // Control arrival order with three separate merges: a1, b1, a2.
    const [a1, a2] = chain(WRITER_A, 2);
    const [b1] = chain(WRITER_B, 1);
    await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: [a1] });
    await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: [b1] });
    await call("POST", `/v1/logs/${LOG_ID}/entries`, { entries: [a2] });

    const p1 = await call("GET", `/v1/logs/${LOG_ID}/entries?limit=2`);
    expect(p1.status).toBe(200);
    expect(p1.body.entries).toEqual([a1, b1]); // arrival order, NOT per-writer order
    expect(typeof p1.body.next_after_arrival).toBe("number");

    const p2 = await call(
      "GET",
      `/v1/logs/${LOG_ID}/entries?after_arrival=${p1.body.next_after_arrival}&limit=2`,
    );
    expect(p2.body.entries).toEqual([a2]);
    expect(p2.body.next_after_arrival).toBeNull();
  });

  it("non-integer after_arrival -> 422 invalid_entry with a reason detail", async () => {
    await createLog();
    const res = await call("GET", `/v1/logs/${LOG_ID}/entries?after_arrival=soon`);
    const error = expectError(res, 422, "invalid_entry");
    expect(String(error.details?.["reason"])).toContain("after_arrival");
  });
});

describe("GET /v1/logs/{log_id}/stats (internal debug route)", () => {
  it("returns counts only — entries and writers, no bodies", async () => {
    await createLog();
    await call("POST", `/v1/logs/${LOG_ID}/entries`, {
      entries: [...chain(WRITER_A, 3), ...chain(WRITER_B, 2)],
    });
    const res = await call("GET", `/v1/logs/${LOG_ID}/stats`);
    expect(res.status).toBe(200);
    expect(res.body).toEqual({ entries: 5, writers: 2 });
  });
});

describe("unknown routes", () => {
  it("an unknown path -> 404 with the recorded 'unknown route' envelope", async () => {
    const res = await call("GET", `/v1/logs/${LOG_ID}/nonsense`);
    const error = expectError(res, 404, "log_not_found");
    expect(error.message).toBe("unknown route");
  });

  it("a known path with an unsupported method -> 404 unknown route", async () => {
    await createLog();
    const res = await call("DELETE", `/v1/logs/${LOG_ID}`);
    const error = expectError(res, 404, "log_not_found");
    expect(error.message).toBe("unknown route");
  });
});

describe("CommonplaceLog.fetch wiring (the real DO class)", () => {
  it("an object addressed WITHOUT a name (newUniqueId) §13.1-rejects every request: 409 log_mismatch, unverifiable-name row", async () => {
    const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.newUniqueId());
    const result = await runInDurableObject(stub, async (instance) => {
      const res = await instance.fetch(
        new Request(`https://do/v1/logs/${LOG_ID}`, {
          method: "PUT",
          body: JSON.stringify({ version: 1 }),
        }),
      );
      // Flatten INSIDE the callback: a Response must not cross the boundary.
      return { status: res.status, body: (await res.json()) as { error: WireError } };
    });
    expect(result.status).toBe(409);
    expect(result.body.error.code).toBe("log_mismatch");
    expect(result.body.error.details?.["reason"]).toContain("no name");
    expect(result.body.error.details?.["reason"]).toContain(LOG_ID);
  });

  it("fetch routes through handleRequest (an unknown path gets the recorded 404 envelope, proving the store+router are wired)", async () => {
    const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.newUniqueId());
    const result = await runInDurableObject(stub, async (instance) => {
      const res = await instance.fetch(new Request("https://do/definitely/not/a/route"));
      return { status: res.status, body: (await res.json()) as { error: WireError } };
    });
    expect(result.status).toBe(404);
    expect(result.body.error.code).toBe("log_not_found");
    expect(result.body.error.message).toBe("unknown route");
  });
});
