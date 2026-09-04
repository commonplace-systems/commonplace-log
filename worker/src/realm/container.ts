import { DurableObject } from "cloudflare:workers";
import { handleRealmRequest } from "./http";
import { handlePublicRealmRequest, RealmAuth } from "./realm_auth";
import { kvRegistry } from "./registry";
import { RealmStore } from "./store";

/** One SQLite-backed Durable Object per realm, containing many named logs. */
interface Env {
  // See node.ts: optional in the type, never optional in production.
  REALM_REGISTRY?: KVNamespace;
  REALM_TEST_LEVERS?: string;
}

export class RealmContainer extends DurableObject<Env> {
  private readonly store = new RealmStore(this.ctx.storage.sql, this.ctx.storage);
  private readonly auth = new RealmAuth(this.ctx.storage.sql, this.ctx.storage);

  override async fetch(request: Request): Promise<Response> {
    return await handlePublicRealmRequest(request, this.auth, async (authorized) =>
      await handleRealmRequest(authorized, this.store),
      kvRegistry(this.env.REALM_REGISTRY), this.env.REALM_TEST_LEVERS === "1");
  }

  /**
   * Platform-authenticated storage entrypoint, mirroring RealmNode.storageFetch:
   * the wire a BEAM inside a Container speaks. Reachable only by Worker code
   * holding a stub (the outbound handler, or a test-only ingress); never via
   * the public fetch, which requires the realm secret.
   */
  async storageFetch(request: Request): Promise<Response> {
    const forwarded = new Request(request);
    forwarded.headers.delete("authorization");
    return await handleRealmRequest(forwarded, this.store);
  }
}
