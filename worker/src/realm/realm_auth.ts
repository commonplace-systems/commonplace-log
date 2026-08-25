import { initRealmMetaSchema } from "./schema";

export const REALM_CREATE_HEADER = "x-commonplace-realm-create";
export const REALM_ID_HEADER = "x-commonplace-realm-id";

interface Transactor {
  transactionSync<T>(fn: () => T): T;
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

  async authorize(request: Request): Promise<"not_found" | "unauthorized" | "authorized"> {
    const expected = storedHash(this.sql);
    if (expected === null) return "not_found";
    const presented = bearer(request);
    if (presented === null) return "unauthorized";
    const actual = await sha256(presented);
    return actual.byteLength === expected.byteLength && crypto.subtle.timingSafeEqual(actual, expected)
      ? "authorized"
      : "unauthorized";
  }
}

function fail(code: string, status: number): Response {
  return Response.json({ ok: false, error: { code } }, { status });
}

export async function handlePublicRealmRequest(
  request: Request,
  auth: RealmAuth,
  authorized: (request: Request) => Promise<Response>,
): Promise<Response> {
  const path = new URL(request.url).pathname;
  if (path === "/realm/create" && request.headers.get(REALM_CREATE_HEADER) === "1") {
    const realmId = request.headers.get(REALM_ID_HEADER);
    if (realmId === null) return fail("malformed_request", 400);
    try {
      const secret = await auth.create(realmId);
      return Response.json({ ok: true, realm_id: realmId, realm_secret: secret }, { status: 201 });
    } catch (error) {
      if (error instanceof RealmExists) return fail("realm_exists", 409);
      throw error;
    }
  }

  // The create endpoint is gateway-internal and never opens with a realm secret.
  if (path === "/realm/create") return fail("not_found", 404);

  const result = await auth.authorize(request);
  if (result === "not_found") return fail("not_found", 404);
  if (result === "unauthorized") return fail("unauthorized", 401);

  const forwarded = new Request(request);
  forwarded.headers.delete("authorization");
  forwarded.headers.delete(REALM_CREATE_HEADER);
  forwarded.headers.delete(REALM_ID_HEADER);
  return await authorized(forwarded);
}
