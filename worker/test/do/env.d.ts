import type { CommonplaceLog } from "../../src/index";

declare module "cloudflare:test" {
  interface ProvidedEnv {
    COMMONPLACE_LOG: DurableObjectNamespace<CommonplaceLog>;
  }
}
