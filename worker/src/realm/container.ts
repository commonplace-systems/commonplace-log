import { DurableObject } from "cloudflare:workers";
import { handleRealmRequest } from "./http";
import { handlePublicRealmRequest, RealmAuth } from "./realm_auth";
import { RealmStore } from "./store";

/** One SQLite-backed Durable Object per realm, containing many named logs. */
export class RealmContainer extends DurableObject {
  private readonly store = new RealmStore(this.ctx.storage.sql, this.ctx.storage);
  private readonly auth = new RealmAuth(this.ctx.storage.sql, this.ctx.storage);

  override async fetch(request: Request): Promise<Response> {
    return await handlePublicRealmRequest(request, this.auth, async (authorized) =>
      await handleRealmRequest(authorized, this.store));
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
