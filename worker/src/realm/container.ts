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
}
