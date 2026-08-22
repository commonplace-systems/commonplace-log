import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";

describe("workers-pool smoke", () => {
  it("executes `select 1` against real DO SQLite storage", async () => {
    const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName("smoke"));
    const value = await runInDurableObject(stub, (instance) => instance.ping());
    expect(value).toBe(1);
  });
});
