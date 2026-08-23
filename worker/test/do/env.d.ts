import type { CommonplaceLog, RealmContainer } from "../../src/index";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    COMMONPLACE_LOG: DurableObjectNamespace<CommonplaceLog>;
    REALM_CONTAINER: DurableObjectNamespace<RealmContainer>;
  }
}
