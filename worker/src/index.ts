import type { RealmContainer } from "./realm/container";
import type { RealmNode } from "./realm/node";
import {
  REALM_ALLOCATE_HEADER,
  REALM_CREATE_HEADER,
  REALM_ID_HEADER,
} from "./realm/realm_auth";

export { CommonplaceLog } from "./commonplace-log-do";
export { RealmContainer } from "./realm/container";
export { RealmNode } from "./realm/node";
export { ContainerProxy } from "@cloudflare/containers";

/**
 * Worker bindings. `GATEWAY_TOKEN` is a Worker *secret* (never a plaintext
 * `vars` entry); tests inject an obviously fake value through the vitest
 * workers config.
 */
export interface Env {
  REALM_CONTAINER: DurableObjectNamespace<RealmContainer>;
  REALM_NODE?: DurableObjectNamespace<RealmNode>;
  GATEWAY_TOKEN?: string;
  REALM_TEST_LEVERS?: string;
}

/**
 * Realm gateway with separate deployment-create and per-realm authorities.
 *
 * Every realm request is `/realms/{realm_id}` + a sidecar path, e.g.
 * `POST /realms/018f1000-0000-7000-8000-000000000001/commit`. The realm is
 * derived ONLY from the URL path and the request is forwarded to
 * `REALM_NODE.getByName(realm_id)` in production,
 * with the `/realms/{realm_id}` prefix stripped; method, headers, body and query
 * pass through untouched. The container-free test configuration deliberately
 * omits that binding and uses `REALM_CONTAINER` instead.
 *
 * This is distinct from the outbound handler of readiness §3 / revision §8.2, which
 * derives the realm from a Container's `containerId` rather than from anything
 * the client sends. A BEAM process inside a Container never talks to this route.
 */

// REALMID-R3: jes ruled question 1 as option 1a on 2026-08-25; see
// docs/proposals/2026-08-25-realm-naming-and-placement.md. Realm ids are opaque.
const REALM_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const REALM_PREFIX = "/realms/";
const BUFFERED_WIRE_PATHS = new Set(["/list-logs", "/restore-bundle-batch"]);
const MAX_BUFFERED_BODY_BYTES = 32 * 1024 * 1024;
const BUFFERED_BODY_DEADLINE_MS = 5_000;

function fail(code: string, status: number): Response {
  return Response.json({ ok: false, error: { code } }, { status });
}

/** Constant-time equality on the UTF-8 encodings; length mismatch is a plain false. */
function tokensEqual(presented: string, expected: string): boolean {
  const encoder = new TextEncoder();
  const a = encoder.encode(presented);
  const b = encoder.encode(expected);
  if (a.byteLength !== b.byteLength) return false;
  return crypto.subtle.timingSafeEqual(a, b);
}

function bearerToken(request: Request): string | null {
  const header = request.headers.get("authorization");
  if (header === null) return null;
  const match = /^Bearer\s+(\S+)\s*$/i.exec(header);
  return match?.[1] ?? null;
}

/** Split `/realms/{realm_id}{rest}`; null when the path is not a well-formed realm route. */
function realmRoute(pathname: string): { realmId: string; sidecarPath: string } | null {
  if (!pathname.startsWith(REALM_PREFIX)) return null;
  const remainder = pathname.slice(REALM_PREFIX.length);
  const slash = remainder.indexOf("/");
  const realmId = slash === -1 ? remainder : remainder.slice(0, slash);
  if (!REALM_ID.test(realmId)) return null;
  return { realmId, sidecarPath: slash === -1 ? "/" : remainder.slice(slash) };
}

function realmStub(env: Env, realmId: string): DurableObjectStub {
  if (env.REALM_NODE !== undefined) {
    return env.REALM_NODE.getByName(realmId);
  }

  // Test-only compatibility path: vitest-pool-workers cannot instantiate a
  // Container subclass because its Durable Object context has no container.
  return env.REALM_CONTAINER.getByName(realmId);
}

const LOCATION_HINTS = new Set([
  "wnam", "enam", "sam", "weur", "eeur", "apac", "oc", "afr", "me",
]);

type LocationHint = DurableObjectNamespaceGetDurableObjectOptions["locationHint"];

function createRealmStub(env: Env, realmId: string, locationHint?: LocationHint): DurableObjectStub {
  const namespace = env.REALM_NODE ?? env.REALM_CONTAINER;
  const id = namespace.idFromName(realmId);
  return namespace.get(id, locationHint === undefined ? undefined : { locationHint });
}

class IngressBodyFailure extends Error {
  constructor(readonly code: "oversize" | "timeout" | "malformed") {
    super(code);
  }
}

/**
 * Buffer only the bounded provider wire body so the DO receives an independent
 * stream. This is transport admission: it does not parse or validate JSON.
 * The 32 MiB bound is retained payload, not a total-memory bound: while the
 * final contiguous copy is built, chunks plus that copy can approach 64 MiB,
 * in addition to runtime stream overhead.
 * Because buffering precedes realm authorization, an over-limit or timed-out
 * request receives the ingress 413/408 result even when its bearer is absent
 * or wrong; this is an explicit bounded-input policy, not an auth guarantee.
 */
async function readBufferedWireBody(
  request: Request,
  maxBytes = MAX_BUFFERED_BODY_BYTES,
): Promise<Uint8Array> {
  if (request.body === null) return new Uint8Array();
  const reader = request.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let timer: ReturnType<typeof setTimeout> | undefined;
  let finished = false;
  let abandoned = false;

  const readAll = async (): Promise<Uint8Array> => {
    while (true) {
      const next = await reader.read();
      if (abandoned) throw new IngressBodyFailure("timeout");
      if (next.done) break;
      total += next.value.byteLength;
      if (total > maxBytes) throw new IngressBodyFailure("oversize");
      chunks.push(next.value);
    }
    if (abandoned) throw new IngressBodyFailure("timeout");
    const body = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
      body.set(chunk, offset);
      offset += chunk.byteLength;
    }
    return body;
  };

  try {
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => reject(new IngressBodyFailure("timeout")), BUFFERED_BODY_DEADLINE_MS);
    });
    const body = await Promise.race([readAll(), timeout]);
    finished = true;
    return body;
  } catch (error) {
    abandoned = true;
    if (error instanceof IngressBodyFailure) throw error;
    throw new IngressBodyFailure("malformed");
  } finally {
    if (timer !== undefined) clearTimeout(timer);
    if (!finished) void reader.cancel().catch(() => undefined);
    try {
      reader.releaseLock();
    } catch {
      // A pending read owns the lock; cancellation remains best-effort and
      // the bounded request result has already been selected.
    }
  }
}

async function bufferWireBodyOrFail(
  request: Request,
): Promise<{ ok: true; body: Uint8Array } | { ok: false; response: Response }> {
  try {
    return { ok: true, body: await readBufferedWireBody(request) };
  } catch (error) {
    if (error instanceof IngressBodyFailure && error.code === "oversize") {
      return { ok: false, response: fail("oversize", 413) };
    }
    if (error instanceof IngressBodyFailure && error.code === "timeout") {
      return { ok: false, response: fail("request_timeout", 408) };
    }
    return { ok: false, response: fail("malformed_request", 400) };
  }
}

async function createBody(request: Request): Promise<{ locationHint?: LocationHint } | null> {
  try {
    const value: unknown = await request.json();
    if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
    const row = value as Record<string, unknown>;
    if (Object.keys(row).some((key) => key !== "location_hint")) return null;
    if (row.location_hint === undefined) return {};
    if (typeof row.location_hint !== "string" || !LOCATION_HINTS.has(row.location_hint)) return null;
    return { locationHint: row.location_hint as LocationHint };
  } catch {
    return null;
  }
}

async function allocationBody(
  request: Request,
): Promise<{ operationId: string; secret: string; locationHint?: LocationHint } | null> {
  try {
    const raw = await readBufferedWireBody(request, 4_096);
    const value: unknown = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(raw));
    if (typeof value !== "object" || value === null || Array.isArray(value)) return null;
    const row = value as Record<string, unknown>;
    if (Object.keys(row).some((key) => !["operation_id", "realm_secret", "location_hint"].includes(key))) return null;
    if (typeof row.operation_id !== "string" || new TextEncoder().encode(row.operation_id).byteLength > 256 || row.operation_id.length === 0) return null;
    if (typeof row.realm_secret !== "string" || !/^[0-9a-f]{64}$/.test(row.realm_secret)) return null;
    if (row.location_hint !== undefined &&
        (typeof row.location_hint !== "string" || !LOCATION_HINTS.has(row.location_hint))) return null;
    return {
      operationId: row.operation_id,
      secret: row.realm_secret,
      ...(row.location_hint === undefined ? {} : { locationHint: row.location_hint as LocationHint }),
    };
  } catch {
    return null;
  }
}

export async function handleIngress(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);

  // The single unauthenticated route: a liveness probe.
  if (url.pathname === "/" && request.method === "GET") {
    return new Response("commonplace-log", { status: 200 });
  }

  const presented = bearerToken(request);
  const route = realmRoute(url.pathname);
  if (route === null) return fail("not_found", 404);

  const isCreate = request.method === "POST" && route.sidecarPath === "/" &&
    url.pathname === `${REALM_PREFIX}${route.realmId}`;

  if (isCreate) {
    const expected = env.GATEWAY_TOKEN;
    if (typeof expected !== "string" || expected.length === 0) {
      return fail("gateway_not_configured", 503);
    }
    if (presented === null || !tokensEqual(presented, expected)) return fail("unauthorized", 401);
    const decoded = await createBody(request);
    if (decoded === null) return fail("malformed_request", 400);

    const target = new URL(request.url);
    target.pathname = "/realm/create";
    const headers = new Headers(request.headers);
    headers.delete("authorization");
    headers.set(REALM_CREATE_HEADER, "1");
    headers.set(REALM_ID_HEADER, route.realmId);
    const forwarded = new Request(target, {
      method: "POST",
      headers,
      body: "{}",
    });
    return await createRealmStub(env, route.realmId, decoded.locationHint).fetch(forwarded);
  }

  const isAllocate = request.method === "POST" && route.sidecarPath === "/allocate";
  if (isAllocate) {
    const expected = env.GATEWAY_TOKEN;
    if (typeof expected !== "string" || expected.length === 0) {
      return fail("gateway_not_configured", 503);
    }
    if (presented === null || !tokensEqual(presented, expected)) return fail("unauthorized", 401);
    const decoded = await allocationBody(request);
    if (decoded === null) return fail("malformed_request", 400);

    const target = new URL(request.url);
    target.pathname = "/realm/allocate";
    const headers = new Headers(request.headers);
    headers.delete("authorization");
    headers.set(REALM_ALLOCATE_HEADER, "1");
    headers.set(REALM_ID_HEADER, route.realmId);
    const forwarded = new Request(target, {
      method: "POST",
      headers,
      body: JSON.stringify({ operation_id: decoded.operationId, realm_secret: decoded.secret }),
    });
    return await createRealmStub(env, route.realmId, decoded.locationHint).fetch(forwarded);
  }

  // Realm routes are scoped in the DO. The gateway checks syntax only.
  const needsBufferedWireBody = request.method === "POST" && BUFFERED_WIRE_PATHS.has(route.sidecarPath);
  let bufferedBody: Uint8Array | undefined;
  if (needsBufferedWireBody) {
    const buffered = await bufferWireBodyOrFail(request);
    if (!buffered.ok) return buffered.response;
    bufferedBody = buffered.body;
  }

  if (presented === null) return fail("unauthorized", 401);

  const target = new URL(request.url);
  target.pathname = route.sidecarPath;
  const headers = new Headers(request.headers);
  headers.delete("content-length");
  headers.delete("transfer-encoding");
  headers.delete(REALM_CREATE_HEADER);
  headers.delete(REALM_ID_HEADER);
  headers.delete(REALM_ALLOCATE_HEADER);
  const forwarded = needsBufferedWireBody
    ? new Request(target, { method: request.method, headers, body: bufferedBody })
    : new Request(target, request);
  forwarded.headers.delete(REALM_CREATE_HEADER);
  forwarded.headers.delete(REALM_ID_HEADER);
  return await realmStub(env, route.realmId).fetch(forwarded);
}

export default {
  fetch: handleIngress,
} satisfies ExportedHandler<Env>;
