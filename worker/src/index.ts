import type { RealmContainer } from "./realm/container";
import type { RealmNode } from "./realm/node";

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
}

/**
 * Authenticated realm gateway (docs/sp4b-deployment-readiness.md §5).
 *
 * Every realm request is `/realms/{realm_id}` + a sidecar path, e.g.
 * `POST /realms/acme-1/commit`. The realm is derived ONLY from the URL path and
 * the request is forwarded to `REALM_NODE.getByName(realm_id)` in production,
 * with the `/realms/{realm_id}` prefix stripped; method, headers, body and query
 * pass through untouched. The container-free test configuration deliberately
 * omits that binding and uses `REALM_CONTAINER` instead.
 *
 * This is distinct from the outbound handler of readiness §3 / revision §8.2, which
 * derives the realm from a Container's `containerId` rather than from anything
 * the client sends. A BEAM process inside a Container never talks to this route.
 */

const REALM_ID = /^[A-Za-z0-9._-]{1,128}$/;
const REALM_PREFIX = "/realms/";

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

export async function handleIngress(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);

  // The single unauthenticated route: a liveness probe.
  if (url.pathname === "/" && request.method === "GET") {
    return new Response("commonplace-log", { status: 200 });
  }

  // A gateway with no configured token fails closed, for every request.
  const expected = env.GATEWAY_TOKEN;
  if (typeof expected !== "string" || expected.length === 0) {
    return fail("gateway_not_configured", 503);
  }

  const presented = bearerToken(request);
  if (presented === null || !tokensEqual(presented, expected)) {
    return fail("unauthorized", 401);
  }

  const route = realmRoute(url.pathname);
  if (route === null) return fail("not_found", 404);

  const target = new URL(request.url);
  target.pathname = route.sidecarPath;
  const forwarded = new Request(target, request);
  // The sidecar has no auth of its own; do not carry the gateway secret into it.
  forwarded.headers.delete("authorization");
  return await realmStub(env, route.realmId).fetch(forwarded);
}

export default {
  fetch: handleIngress,
} satisfies ExportedHandler<Env>;
