import { DurableObject } from "cloudflare:workers";
import { handleAuthenticatedRequest, handleStorageRequest } from "./wire";
import { handlePublicRealmRequest, isRealmLifecycleRequest, RealmAuth } from "./realm_auth";
import { kvRegistry } from "./registry";
import { RealmStore } from "./store";

interface Env { REALM_REGISTRY?: KVNamespace; REALM_TEST_LEVERS?: string; }
export class RealmContainer extends DurableObject<Env> {
  private readonly store = new RealmStore(this.ctx.storage.sql, this.ctx.storage);
  private readonly auth = new RealmAuth(this.ctx.storage.sql, this.ctx.storage);
  override async fetch(request: Request): Promise<Response> {
    const dispatch = () => handlePublicRealmRequest(request, this.auth, async (authorized) =>
      await handleAuthenticatedRequest(authorized, this.store), kvRegistry(this.env.REALM_REGISTRY),
      this.env.REALM_TEST_LEVERS === "1", () => this.ctx.storage.deleteAll(), this.ctx.id.name);
    if (isRealmLifecycleRequest(request)) return await this.ctx.blockConcurrencyWhile(dispatch);
    return await dispatch();
  }
  async storageFetch(request: Request): Promise<Response> {
    const forwarded = new Request(request); forwarded.headers.delete("authorization");
    return await handleStorageRequest(forwarded, this.store);
  }
}
