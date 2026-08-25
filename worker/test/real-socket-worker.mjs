import { RealmContainer } from "../src/realm/container.ts";

export { RealmContainer };

/**
 * Test-only ingress: route the real HTTP socket to one real realm Durable
 * Object over the SAME wire a BEAM inside a Container uses — the
 * platform-authenticated storageFetch RPC — not the public fetch, which since
 * the per-realm-secret ruling requires a created realm and its secret.
 */
export default {
  async fetch(request, env) {
    const realm = env.REALM_CONTAINER.getByName("elixir-real-socket-integration");
    return realm.storageFetch(request);
  },
};
