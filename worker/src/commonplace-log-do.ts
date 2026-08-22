import { DurableObject } from "cloudflare:workers";
import { handleRequest } from "./do/http";
import { LogStore } from "./do/store";

/**
 * The CommonplaceLog SQLite-backed Durable Object: a thin shell wiring
 * ctx.storage (SqlStorage + transactionSync, both consumed inside LogStore)
 * and ctx.id.name (§13.1 name <-> log_id verification) to the §11 HTTP
 * surface in do/http.ts. No correctness state lives on this class (§15.2):
 * the store reads SQLite truth on every operation.
 */
export class CommonplaceLog extends DurableObject {
  private readonly store = new LogStore(this.ctx.storage.sql, this.ctx.storage);

  override async fetch(request: Request): Promise<Response> {
    return handleRequest(request, {
      store: this.store,
      // undefined when the object was addressed by unique id rather than
      // idFromName — http.ts rejects that explicitly (§13.1).
      objectName: this.ctx.id.name,
    });
  }

  /** Smoke check: proves real DO SQLite storage is reachable. */
  ping(): number {
    const row = this.ctx.storage.sql.exec("select 1 as one").one();
    return Number(row.one);
  }
}
