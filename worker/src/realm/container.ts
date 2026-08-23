import { DurableObject } from "cloudflare:workers";
import { handleRealmRequest } from "./http";
import { RealmStore } from "./store";

/** One SQLite-backed Durable Object per realm, containing many named logs. */
export class RealmContainer extends DurableObject {
  private readonly store = new RealmStore(this.ctx.storage.sql, this.ctx.storage);

  override async fetch(request: Request): Promise<Response> {
    return await handleRealmRequest(request, this.store);
  }
}
