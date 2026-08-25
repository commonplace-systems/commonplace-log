import { describe, expect, it } from "vitest";
import { containerFetchWithCapacityMapping } from "../../src/realm/capacity";

describe("RealmNode container capacity mapping", () => {
  it("maps the platform capacity start failure to realm_capacity", async () => {
    const response = await containerFetchWithCapacityMapping(async () => {
      throw new Error("start failed: Maximum number of running container instances exceeded (limit)");
    });
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ ok: false, error: { code: "realm_capacity" } });
  });

  it("lets unrelated container errors propagate", async () => {
    const error = new Error("container is not listening");
    await expect(containerFetchWithCapacityMapping(async () => { throw error; })).rejects.toBe(error);
  });
});
