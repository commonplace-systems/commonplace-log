import { initRealmMetaSchema } from "./schema";

import { RealmRegistry, RegistryOutcome } from "./registry";

export const REALM_CREATE_HEADER = "x-commonplace-realm-create";
export const REALM_ID_HEADER = "x-commonplace-realm-id";

/**
 * STORE-3b. Minting and revoking the read capability.
 * ⛔ THIS PATH IS ITSELF A WRITE ROUTE -- it is absent from READ_ROUTES and refused explicitly
 * above -- so a read capability can never mint another and the write secret remains the only root.
 */
export const READ_CAPABILITY_PATH = "/realm/read-capability";

interface Transactor {
  transactionSync<T>(fn: () => T): T;
}

export class ReadCapabilityExists extends Error {
  constructor() {
    super("read_capability_exists");
    this.name = "ReadCapabilityExists";
  }
}

export class RealmMissing extends Error {
  constructor() {
    super("not_found");
    this.name = "RealmMissing";
  }
}

export class RealmExists extends Error {
  constructor() {
    super("realm_exists");
    this.name = "RealmExists";
  }
}

function hasRealmMetaTable(sql: SqlStorage): boolean {
  return sql
    .exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'realm_meta'")
    .toArray().length > 0;
}

function secretBytes(): Uint8Array {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return bytes;
}

function hex(bytes: Uint8Array): string {
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function sha256(value: string): Promise<Uint8Array> {
  return new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value)));
}

function bearer(request: Request): string | null {
  const value = request.headers.get("authorization");
  if (value === null) return null;
  return /^Bearer\s+(\S+)\s*$/i.exec(value)?.[1] ?? null;
}

function storedHash(sql: SqlStorage): Uint8Array | null {
  if (!hasRealmMetaTable(sql)) return null;
  const row = sql.exec("SELECT secret_hash FROM realm_meta WHERE singleton = 1").toArray()[0];
  return row === undefined ? null : new Uint8Array(row.secret_hash as ArrayBuffer);
}

function storedReadHash(sql: SqlStorage): Uint8Array | null {
  if (!hasRealmMetaTable(sql)) return null;
  const row = sql.exec("SELECT read_secret_hash FROM realm_meta WHERE singleton = 1").toArray()[0];
  if (row === undefined) return null;
  const value = row.read_secret_hash;
  return value === null || value === undefined ? null : new Uint8Array(value as ArrayBuffer);
}

async function matches(presented: string, expected: Uint8Array | null): Promise<boolean> {
  if (expected === null) return false;
  const actual = await sha256(presented);
  return actual.byteLength === expected.byteLength &&
    crypto.subtle.timingSafeEqual(actual, expected);
}

/**
 * STORE-3b. The routes a READ capability may reach.
 *
 * ⛔ THE WRITE SET IS THE COMPLEMENT AND IS NEVER ENUMERATED SEPARATELY. A second list would be a
 * second thing to keep in step, and a route added to one and not the other would be reachable by a
 * read capability with nothing to notice -- absence is the failure mode this whole file guards.
 * ⇒ Anything not named here is a write route, including `/realm/read-capability` itself, which is
 * why a read capability can never mint another and the write secret stays the only root.
 */
const READ_ROUTES: ReadonlySet<string> = new Set([
  "/frontier",
  "/read-set",
  "/read-writer",
  "/tail-local",
]);

export type Scope = "write" | "read";

export class RealmAuth {
  constructor(
    private readonly sql: SqlStorage,
    private readonly txn: Transactor,
  ) {}

  async create(realmId: string): Promise<string> {
    if (storedHash(this.sql) !== null) throw new RealmExists();
    const secret = hex(secretBytes());
    const hash = await sha256(secret);
    initRealmMetaSchema(this.sql);

    return this.txn.transactionSync(() => {
      if (storedHash(this.sql) !== null) throw new RealmExists();
      this.sql.exec(
        "INSERT INTO realm_meta (singleton, secret_hash, created_at) VALUES (1, ?, ?)",
        hash.buffer.slice(hash.byteOffset, hash.byteOffset + hash.byteLength),
        new Date().toISOString(),
      );
      return secret;
    });
  }

  /**
   * ⛔ RETURNS A SCOPE, NOT A BOOLEAN VERDICT. Before STORE-3b any valid secret was full authority
   * over all seven routes; the caller had nothing to consult and no way to attenuate.
   * ⚠️ BOTH hashes are compared with `timingSafeEqual` and NEITHER comparison short-circuits on a
   * length test that leaks which secret was presented.
   */
  async authorize(request: Request): Promise<"not_found" | "unauthorized" | Scope> {
    const expected = storedHash(this.sql);
    if (expected === null) return "not_found";
    const presented = bearer(request);
    if (presented === null) return "unauthorized";
    if (await matches(presented, expected)) return "write";
    if (await matches(presented, storedReadHash(this.sql))) return "read";
    return "unauthorized";
  }

  /** Mint the read capability. Refuses if one exists -- rotation is DELETE then mint, never silent. */
  async mintReadCapability(): Promise<string> {
    if (storedHash(this.sql) === null) throw new RealmMissing();
    if (storedReadHash(this.sql) !== null) throw new ReadCapabilityExists();
    const secret = hex(secretBytes());
    const hash = await sha256(secret);

    return this.txn.transactionSync(() => {
      // ⛔ RE-CHECKED INSIDE THE TRANSACTION, mirroring `create` above: the check and the write are
      // one unit or two callers can both pass the check and the second overwrites the first's
      // capability, revoking it silently at HTTP 201.
      if (storedReadHash(this.sql) !== null) throw new ReadCapabilityExists();
      this.sql.exec(
        "UPDATE realm_meta SET read_secret_hash = ?, read_created_at = ? WHERE singleton = 1",
        hash.buffer.slice(hash.byteOffset, hash.byteOffset + hash.byteLength),
        new Date().toISOString(),
      );
      return secret;
    });
  }

  /** Revoke it. Idempotent: revoking an absent capability is not an error, it is the state asked for. */
  revokeReadCapability(): void {
    this.txn.transactionSync(() => {
      this.sql.exec(
        "UPDATE realm_meta SET read_secret_hash = NULL, read_created_at = NULL WHERE singleton = 1",
      );
    });
  }
}

/**
 * ⭐ `details` is OPTIONAL and ADDITIVE: every existing arm asserts `error.code` and is unaffected.
 * It exists because of BACKUP-1a's own finding against this codebase's neighbour -- `uuid-malformed`
 * names WHAT is wrong and not WHERE, and it cost two wrong guesses before the field was found. An
 * error that can name its subject should.
 */
function fail(code: string, status: number, details?: Record<string, string>): Response {
  return Response.json(
    { ok: false, error: details === undefined ? { code } : { code, details } },
    { status },
  );
}

/** Both lifecycle operations must hold the DO input gate through their external KV await.
 * Otherwise recreation can register while an older removal is awaiting KV, and that
 * removal can erase the new live realm's row. Ordinary requests need no extra gate.
 */
export function isRealmLifecycleRequest(request: Request): boolean {
  const path = new URL(request.url).pathname;
  return path === "/realm/create" || (request.method === "DELETE" && path === "/");
}

export async function handlePublicRealmRequest(
  request: Request,
  auth: RealmAuth,
  authorized: (request: Request) => Promise<Response>,
  registry?: RealmRegistry,
  // ⛔ DEFAULT IS THE SAFE ONE. A caller that forgets this flag gets the REFUSAL, not the silent
  // 201 -- the unsafe behaviour has to be asked for by name.
  allowUnboundRegistry = false,
  wipeStorage?: () => Promise<void>,
): Promise<Response> {
  const path = new URL(request.url).pathname;
  if (path === "/realm/create" && request.headers.get(REALM_CREATE_HEADER) === "1") {
    const realmId = request.headers.get(REALM_ID_HEADER);
    if (realmId === null) return fail("malformed_request", 400);
    try {
      // ⛔⛔ THE BINDING IS CHECKED *BEFORE* THE REALM IS CREATED, AND THE ORDER IS THE POINT.
      // An unbound registry is a DEPLOY-TIME fact (a missing `wrangler.jsonc` binding), so this
      // refusal is not about this request -- it is about the deployment. ⇒ Refusing AFTER `create`
      // would leave an ORPHAN: a realm that exists, is unregistered, and whose write secret the
      // caller never received, so nobody can reach it and nothing can back it up. Refusing FIRST
      // creates nothing. (plan row 855: a 201 over an unregistered realm is the silent-underreport
      // shape -- the system answering instead of declining.)
      if (registry === undefined && !allowUnboundRegistry) {
        return fail("registry_not_bound", 503, {
          binding: "REALM_REGISTRY",
          detail: "realm creation is disabled while the registry binding is absent",
        });
      }

      const secret = await auth.create(realmId);
      // ⭐ MINT AND REGISTER IN THE SAME ACT. The authority to mint is BEING INSIDE THIS DO --
      // `mintReadCapability()` takes no argument and never sees the write secret (BACKUP-1a's
      // premise correction, plan row 854). ⛔ The capability is NOT returned over the wire: it
      // goes to the registry and nowhere else, so the gateway never holds a read capability.
      const registered = await registerRealm(auth, registry, realmId);
      return Response.json(
        { ok: true, realm_id: realmId, realm_secret: secret, registry: registered },
        { status: 201 },
      );
    } catch (error) {
      if (error instanceof RealmExists) return fail("realm_exists", 409);
      throw error;
    }
  }

  // The create endpoint is gateway-internal and never opens with a realm secret.
  if (path === "/realm/create") return fail("not_found", 404);

  const isRemoval = request.method === "DELETE" && path === "/";
  const result = await auth.authorize(request);
  // Only exact removal may answer at all after the realm's auth tables are gone.
  if (result === "not_found" && !isRemoval) return fail("not_found", 404);
  if (result === "unauthorized") return fail("unauthorized", 401);

  // ⛔⛔ AN UNAUTHENTICATED REMOVAL HAS NO SIDE EFFECT. Reaching here with `not_found` means the
  // realm's auth table is absent, so NOTHING was proved about the caller -- `authorize` returned
  // before comparing any secret. The state the caller asked for ALREADY HOLDS, so 204 is honest and
  // the request must touch nothing on the way out.
  // ⚠️ THIS IS NARROWER THAN IT LOOKS AND THE DIFFERENCE IS THE POINT: 204 here and a registry
  // delete here are ONE CODE PATH, and the second sentence is "any caller who guesses a realm id
  // can erase its registry row". An ORPHAN row is the safer of the two states -- it is VISIBLE to
  // `BACKUP-1b-iii`'s reconciliation, which removes rows whose DO reads not_found under the
  // Worker's OWN binding, rather than sweepable by an unauthenticated guess.
  // ⏳ COST, STATED: until 1b-iii lands an orphan row is unclearable in band. The in-band repair
  // would be a gateway-authenticated operator retry, and that lane is a STOP boundary in this
  // round -- so it is 1b-iii's design question, not this branch's. (plan row 941/941-bis.)
  if (result === "not_found") return new Response(null, { status: 204 });

  // ⭐ STORE-3b's ONE DECISION POINT, and it lives HERE rather than at either caller. This function
  // is called from BOTH `realm/node.ts` and `realm/container.ts`; a scope check placed in a caller
  // would leave the other lane unscoped, and the two lanes would disagree with nothing to notice.
  // ⇒ Two call sites, one check. Same reason A6 reads the artifact rather than the boot script.
  if (result === "read") {
    if (path === READ_CAPABILITY_PATH) return fail("forbidden_scope", 403);
    if (!READ_ROUTES.has(path)) return fail("forbidden_scope", 403);
  }

  if (path === READ_CAPABILITY_PATH) {
    // Reached only with scope "write" -- the read case is refused above.
    if (request.method === "POST") {
      try {
        const secret = await auth.mintReadCapability();
        return Response.json({ ok: true, read_secret: secret }, { status: 201 });
      } catch (error) {
        if (error instanceof ReadCapabilityExists) return fail("read_capability_exists", 409);
        if (error instanceof RealmMissing) return fail("not_found", 404);
        throw error;
      }
    }
    if (request.method === "DELETE") {
      auth.revokeReadCapability();
      return new Response(null, { status: 204 });
    }
    return fail("method_not_allowed", 405);
  }

  if (isRemoval) {
    // The gateway overwrites this from the canonical route, never from client headers.
    // It survives SQL deletion so a retry can remove an orphan registry row.
    const realmId = request.headers.get(REALM_ID_HEADER);
    if (realmId === null || realmId.length === 0) return fail("malformed_request", 400);
    if (registry === undefined && !allowUnboundRegistry) {
      return fail("registry_not_bound", 503, { binding: "REALM_REGISTRY" });
    }
    if (wipeStorage === undefined) return fail("removal_not_configured", 503);

    // Registry FIRST then storage failure leaves a LIVE AND UNREGISTERED realm:
    // reachable with its capability, absent from the backup inventory and invisible
    // to every check OF that inventory. It manufactures the BACKUP-1b-iii
    // reconciliation hole. Reverse failure is benign and self-announcing: storage
    // gone, an orphan registry row, and the count control reads one too many.
    await wipeStorage(); // The DO supplies state.storage.deleteAll(); await it FIRST.
    const outcome: RegistryOutcome = await unregisterRealm(registry, realmId);
    if (outcome === "registry_delete_failed") {
      return Response.json(
        { ok: false, error: { code: outcome }, registry: outcome },
        { status: 503 },
      );
    }
    return new Response(null, { status: 204 });
  }

  const forwarded = new Request(request);
  forwarded.headers.delete("authorization");
  forwarded.headers.delete(REALM_CREATE_HEADER);
  forwarded.headers.delete(REALM_ID_HEADER);
  return await authorized(forwarded);
}


async function unregisterRealm(
  registry: RealmRegistry | undefined,
  realmId: string,
): Promise<RegistryOutcome> {
  if (registry === undefined) return "no_registry_bound";
  try {
    await registry.delete(realmId);
    return "deleted";
  } catch {
    return "registry_delete_failed";
  }
}

/**
 * Mint this realm's read capability and hand it to the registry, reporting WHICH outcome occurred.
 *
 * ⛔⛔ NOTHING HERE IS SILENT, AND THAT IS THE WHOLE DESIGN. A realm that exists but is not
 * registered is invisible to the backup; if this returned `void` and swallowed a failure, the
 * create would look identical in all four cases and the gap would surface only as a backup that
 * was quietly short. ⇒ The outcome rides in the 201 body.
 *
 * ⛔ The realm is NOT unwound on a registry failure. The caller already holds a write secret for a
 * realm that exists; failing the response would leave them unable to reach it. A missing registry
 * row is recoverable (retroactive mint + register, BACKUP-1b-iii); a lost write secret is not.
 */
async function registerRealm(
  auth: RealmAuth,
  registry: RealmRegistry | undefined,
  realmId: string,
): Promise<RegistryOutcome> {
  if (registry === undefined) return "no_registry_bound";

  let capability: string;
  try {
    capability = await auth.mintReadCapability();
  } catch (error) {
    // ⭐ A capability already exists, so this realm's was minted by someone else and this create
    // cannot know its value. NAMED, never treated as success.
    if (error instanceof ReadCapabilityExists) return "already_minted";
    throw error;
  }

  try {
    await registry.put(realmId, capability);
  } catch {
    return "registry_write_failed";
  }
  return "registered";
}
