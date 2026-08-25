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

  it("maps the platform's actual shape: a resolved 500 Response carrying the message", async () => {
    // Observed on the real platform 2026-08-25; the SDK resolves rather than throws.
    const response = await containerFetchWithCapacityMapping(async () =>
      new Response(
        "Failed to start container: Maximum number of running container instances exceeded. Try again later",
        { status: 500 },
      ));
    expect(response.status).toBe(503);
    expect(await response.json()).toEqual({ ok: false, error: { code: "realm_capacity" } });
  });

  it("passes an unrelated 500 Response through with its body intact", async () => {
    const response = await containerFetchWithCapacityMapping(async () =>
      new Response("Error proxying request to container: not listening", { status: 500 }));
    expect(response.status).toBe(500);
    expect(await response.text()).toContain("not listening");
  });

  it("lets unrelated container errors propagate", async () => {
    const error = new Error("container is not listening");
    await expect(containerFetchWithCapacityMapping(async () => { throw error; })).rejects.toBe(error);
  });
});
