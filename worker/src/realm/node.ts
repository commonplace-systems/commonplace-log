import { Container } from "@cloudflare/containers";
import { handleRealmRequest } from "./http";
import { storageInternal } from "./outbound";
import { RealmStore } from "./store";

interface Env {
  REALM_NODE: DurableObjectNamespace<RealmNode>;
  REALM_TEST_LEVERS?: string;
}

/** One Container-managing Durable Object and SQLite sidecar per realm. */
export class RealmNode extends Container<Env> {
  defaultPort = 4000;
  sleepAfter = "10m";
  enableInternet = false;
  // Development-only test controls are explicitly bridged into the BEAM container.
  envVars = {
    COMMONPLACE_REALM_TEST_LEVERS: this.env.REALM_TEST_LEVERS ?? "",
  };

  private readonly store = new RealmStore(this.ctx.storage.sql, this.ctx.storage);

  override async fetch(request: Request): Promise<Response> {
    const url = new URL(request.url);

    if (request.method === "GET" && url.pathname === "/node/restart") {
      await this.stop();
      return Response.json({ ok: true }, { status: 202 });
    }

    if (url.pathname.startsWith("/engine/")) {
      url.pathname = url.pathname.slice("/engine".length);
      return await this.containerFetch(new Request(url, request));
    }

    return await handleRealmRequest(request, this.store);
  }
}

// A class field uses define semantics and bypasses the SDK's static setter.
RealmNode.outboundByHost = { "storage.internal": storageInternal };
