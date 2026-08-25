/** The platform-provided identity and metadata for a Container outbound call. */
export interface ContainerOutboundContext {
  containerId: string;
  className: string;
  params?: unknown;
}

/** Structural subset used here, kept small so the handler is plain-node testable. */
export interface RealmNodeBinding<Id> {
  idFromString(value: string): Id;
  get(id: Id): { storageFetch(request: Request): Promise<Response> | Response };
}

export interface StorageInternalEnv<Id> {
  REALM_NODE: RealmNodeBinding<Id>;
}

const PLACEHOLDER_ORIGIN = "https://realm-node.internal";

function forbidden(): Response {
  return Response.json({ ok: false, error: { code: "forbidden" } }, { status: 403 });
}

/**
 * Route BEAM storage traffic to this Container's managing Durable Object.
 *
 * The Durable Object identity comes exclusively from the platform's
 * `ctx.containerId`. No request-controlled value participates in selection.
 */
export async function storageInternal<Id>(
  request: Request,
  env: StorageInternalEnv<Id>,
  ctx: ContainerOutboundContext,
): Promise<Response> {
  const incomingUrl = new URL(request.url);
  if (incomingUrl.hostname !== "storage.internal") return forbidden();

  const id = env.REALM_NODE.idFromString(ctx.containerId);
  const stub = env.REALM_NODE.get(id);

  const target = new URL(incomingUrl.pathname + incomingUrl.search, PLACEHOLDER_ORIGIN);
  const forwarded = new Request(target, request);
  // The sidecar authenticates by the platform-supplied Container identity, not
  // by a credential a process inside the Container can manufacture.
  forwarded.headers.delete("authorization");
  return await stub.storageFetch(forwarded);
}
