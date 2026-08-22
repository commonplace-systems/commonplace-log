import { DurableObject } from "cloudflare:workers";

/**
 * SP2 Task 1 scaffold: the minimal SQLite-backed Durable Object.
 * Schema, store operations, and the HTTP surface arrive in Tasks 2+.
 */
export class CommonplaceLog extends DurableObject {
  /** Smoke check: proves real DO SQLite storage is reachable. */
  ping(): number {
    const row = this.ctx.storage.sql.exec("select 1 as one").one();
    return Number(row.one);
  }
}
