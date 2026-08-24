import type { CommonplaceLog, RealmContainer } from "../../src/index";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    COMMONPLACE_LOG: DurableObjectNamespace<CommonplaceLog>;
    REALM_CONTAINER: DurableObjectNamespace<RealmContainer>;
    /** Injected by vitest.workers.config.ts (miniflare.bindings); an obviously fake literal. */
    GATEWAY_TOKEN: string;
  }
}
