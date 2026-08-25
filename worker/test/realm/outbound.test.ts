import { describe, expect, it } from "vitest";
import { storageInternal, type StorageInternalEnv } from "../../src/realm/outbound";

function fakeEnv() {
  const resolved: string[] = [];
  const selected: Array<{ durableObjectId: { value: string }; request: Request }> = [];
  const env: StorageInternalEnv<{ value: string }> = {
    REALM_NODE: {
      idFromString(value) {
        resolved.push(value);
        return { value };
      },
      get(durableObjectId) {
        return {
          async storageFetch(request) {
            selected.push({ durableObjectId, request });
            return Response.json({ ok: true, selected: durableObjectId.value }, { status: 207 });
          },
        };
      },
    },
  };
  return { env, resolved, selected };
}

describe("storageInternal", () => {
  it("refuses a request for any host other than storage.internal", async () => {
    const fake = fakeEnv();
    const response = await storageInternal(
      new Request("https://elsewhere.invalid/frontier"),
      fake.env,
      { containerId: "platform-do-a", className: "RealmNode" },
    );

    expect(response.status).toBe(403);
    expect(await response.json()).toEqual({ ok: false, error: { code: "forbidden" } });
    expect(fake.resolved).toEqual([]);
    expect(fake.selected).toEqual([]);
  });

  it("selects only ctx.containerId even when the request names another realm", async () => {
    const fake = fakeEnv();
    const request = new Request("http://storage.internal/commit?realm_id=request-realm-b", {
      method: "POST",
      headers: {
        "content-type": "application/json",
        "x-realm-id": "header-realm-b",
      },
      body: JSON.stringify({ realm_id: "body-realm-b", log_id: "log-b" }),
    });

    const response = await storageInternal(request, fake.env, {
      containerId: "platform-do-a",
      className: "RealmNode",
      params: { realmId: "ignored-param-realm-b" },
    });

    expect(response.status).toBe(207);
    expect(await response.json()).toEqual({ ok: true, selected: "platform-do-a" });
    expect(fake.resolved).toEqual(["platform-do-a"]);
    expect(fake.selected).toHaveLength(1);
    expect(fake.selected[0]!.durableObjectId).toEqual({ value: "platform-do-a" });
    expect(await fake.selected[0]!.request.json()).toEqual({ realm_id: "body-realm-b", log_id: "log-b" });
  });

  it("rewrites the origin, preserves path/query/method/body, and strips authorization", async () => {
    const fake = fakeEnv();
    await storageInternal(new Request("http://storage.internal/read-set?trace=one", {
      method: "POST",
      headers: {
        authorization: "must-be-removed",
        "content-type": "application/json",
        "x-sidecar-trace": "kept",
      },
      body: JSON.stringify({ log_id: "log-a" }),
    }), fake.env, { containerId: "platform-do-a", className: "RealmNode" });

    const forwarded = fake.selected[0]!.request;
    expect(forwarded.url).toBe("https://realm-node.internal/read-set?trace=one");
    expect(forwarded.method).toBe("POST");
    expect(forwarded.headers.get("authorization")).toBeNull();
    expect(forwarded.headers.get("x-sidecar-trace")).toBe("kept");
    expect(await forwarded.json()).toEqual({ log_id: "log-a" });
  });
});
