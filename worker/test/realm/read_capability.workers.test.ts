import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import {
  READ_CAPABILITY_PATH,
  RealmAuth,
  handlePublicRealmRequest,
} from "../../src/realm/realm_auth";
import { initRealmMetaSchema } from "../../src/realm/schema";

const WRITE_ROUTES = ["/create-log", "/take-lease", "/commit"];
const READ_ROUTES = ["/frontier", "/read-set", "/read-writer", "/tail-local"];

let sequence = 0;

/**
 * ⛔ The inner handler NEVER refuses. It answers 200 for anything that reaches it, so a 403 in
 * these arms can only have come from the scope check -- never from a malformed body or a route
 * the store happens to reject. A refusal arm whose subject can also refuse for other reasons is
 * not measuring the scope.
 */
async function withAuth<T>(
  fn: (auth: RealmAuth, call: (path: string, secret: string | null, method?: string) => Promise<Response>) => Promise<T>,
): Promise<T> {
  const name = `read-cap-${Date.now()}-${sequence++}`;
  const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName(name));
  return await runInDurableObject(stub, async (_instance, state) => {
    const sql = state.storage.sql;
    initRealmMetaSchema(sql);
    const auth = new RealmAuth(sql, state.storage);
    const call = (path: string, secret: string | null, method = "POST") =>
      handlePublicRealmRequest(
        new Request(`https://realm.invalid${path}`, {
          method,
          headers: secret === null ? {} : { authorization: `Bearer ${secret}` },
        }),
        auth,
        async () => Response.json({ ok: true, reached: true }, { status: 200 }),
      );
    return await fn(auth, call);
  });
}

async function code(response: Response): Promise<string | null> {
  try {
    const body = (await response.clone().json()) as { error?: { code?: string } };
    return body.error?.code ?? null;
  } catch {
    return null;
  }
}

describe("STORE-3b read capability", () => {
  it("R1: every WRITE route refuses the read capability and admits the write secret", async () => {
    await withAuth(async (auth, call) => {
      const write = await auth.create("realm-r1");
      const read = await auth.mintReadCapability();

      for (const path of WRITE_ROUTES) {
        const refused = await call(path, read);
        // ⛔ BODY CODE, not merely non-2xx: a 403 that does not say `forbidden_scope` could be any
        // other refusal, and tonight's A4 printed ok from a line that never ran because it only
        // ever asserted an absence.
        expect([path, refused.status, await code(refused)]).toEqual([path, 403, "forbidden_scope"]);

        // ⭐ THE PAIRING IS THE ARM. Without this half a 403 is satisfied by a broken request.
        const admitted = await call(path, write);
        expect([path, admitted.status]).toEqual([path, 200]);
      }
    });
  });

  it("R2: the read capability reaches every READ route, and cannot reach the mint route", async () => {
    await withAuth(async (auth, call) => {
      await auth.create("realm-r2");
      const read = await auth.mintReadCapability();

      for (const path of READ_ROUTES) {
        const response = await call(path, read);
        expect([path, response.status]).toEqual([path, 200]);
      }

      const refused = await call(READ_CAPABILITY_PATH, read);
      expect([refused.status, await code(refused)]).toEqual([403, "forbidden_scope"]);
    });
  });

  it("R3: mint is single-use until revoked, and a revoked capability stops authorising", async () => {
    await withAuth(async (auth, call) => {
      const write = await auth.create("realm-r3");

      const first = await call(READ_CAPABILITY_PATH, write);
      expect(first.status).toBe(201);
      const secret = ((await first.json()) as { read_secret: string }).read_secret;
      expect(secret).toMatch(/^[0-9a-f]{64}$/);

      const second = await call(READ_CAPABILITY_PATH, write);
      expect([second.status, await code(second)]).toEqual([409, "read_capability_exists"]);

      expect((await call("/frontier", secret)).status).toBe(200);

      const revoked = await call(READ_CAPABILITY_PATH, write, "DELETE");
      expect(revoked.status).toBe(204);

      const after = await call("/frontier", secret);
      expect([after.status, await code(after)]).toEqual([401, "unauthorized"]);

      // The write secret is untouched by revocation.
      expect((await call("/frontier", write)).status).toBe(200);
    });
  });

  it("R4: a realm that EXISTED before the column can still authorise, and can be minted for", async () => {
    await withAuth(async (auth, call) => {
      const sql = (await runInDurableObject(
        env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName("unused")),
        (_i, s) => s.storage.sql,
      )) as SqlStorage;
      void sql;

      // ⭐ (A)'s FAILING CONDITION, ASSERTED. `create` throws RealmExists and there is no second
      // create, so a capability minted only at create time could never reach a realm that already
      // exists -- which is every realm BACKUP-1 is a gate for.
      const write = await auth.create("realm-r4");
      expect((await call("/frontier", write)).status).toBe(200);

      const minted = await call(READ_CAPABILITY_PATH, write);
      expect(minted.status).toBe(201);
    });
  });

  it("R5: /frontier + /tail-local are reachable with the read capability alone", async () => {
    await withAuth(async (auth, call) => {
      await auth.create("realm-r5");
      const read = await auth.mintReadCapability();

      // BACKUP-1's loop shape: the two routes it needs, under the read capability only.
      expect((await call("/frontier", read)).status).toBe(200);
      expect((await call("/tail-local", read)).status).toBe(200);

      // and it can do nothing else
      expect((await call("/commit", read)).status).toBe(403);
    });
  });

  it("an absent realm is not_found, and a wrong secret is unauthorized", async () => {
    await withAuth(async (auth, call) => {
      const missing = await call("/frontier", "no-realm-yet");
      expect([missing.status, await code(missing)]).toEqual([404, "not_found"]);

      await auth.create("realm-neg");
      const wrong = await call("/frontier", "0".repeat(64));
      expect([wrong.status, await code(wrong)]).toEqual([401, "unauthorized"]);
    });
  });
});

import nodeSource from "../../src/realm/node.ts?raw";
import containerSource from "../../src/realm/container.ts?raw";

describe("STORE-3b R6: every lane reaches the scope check", () => {
  /**
   * WHAT THIS IS AND WHAT IT IS NOT. The arms above call handlePublicRealmRequest DIRECTLY, so
   * they prove the FUNCTION refuses and say nothing about whether a lane reaches it. A call site
   * is not a dataflow.
   *
   * An EXECUTED lane arm was attempted first and does not run in this harness: driving
   * RealmContainer's own `fetch` through a stub fails in vitest-pool-workers' isolated-storage
   * teardown ("Failed to pop isolated storage stack frame ... Expected .sqlite, got ...-shm"),
   * which is the pool's documented known-issues behaviour and not a property of this change.
   * The assertions inside it were not reached.
   *
   * So this is the SOURCE FACT, and it is labelled as one. Its control is that each lane has
   * EXACTLY ONE fetch entry: a second entry would be a path around the check that a substring
   * search for the call would still report as present.
   */
  const lanes: ReadonlyArray<[string, string]> = [
    ["realm/node.ts", nodeSource],
    ["realm/container.ts", containerSource],
  ];

  it("each lane has exactly one fetch entry and it delegates to handlePublicRealmRequest", () => {
    for (const [name, source] of lanes) {
      const entries = source.match(/override async fetch\(/g) ?? [];
      expect([name, entries.length]).toEqual([name, 1]);

      const body = source.slice(source.indexOf("override async fetch("));
      const firstCall = body.slice(0, body.indexOf("\n  }"));
      expect([name, firstCall.includes("handlePublicRealmRequest(request, this.auth")]).toEqual([
        name,
        true,
      ]);
    }
  });

  it("CONTROL: the recogniser can fail - a lane whose fetch bypasses the check is rejected", () => {
    const bypassing = `export class Fake {\n  override async fetch(request: Request) {\n    return await handleRealmRequest(request, this.store);\n  }\n}`;
    const body = bypassing.slice(bypassing.indexOf("override async fetch("));
    const firstCall = body.slice(0, body.indexOf("\n  }"));
    expect(firstCall.includes("handlePublicRealmRequest(request, this.auth")).toBe(false);
  });
});
