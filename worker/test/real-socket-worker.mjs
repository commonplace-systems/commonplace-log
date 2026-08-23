import { RealmContainer } from "../src/realm/container.ts";

export { RealmContainer };

/** Test-only ingress: route the real HTTP socket to one real realm Durable Object. */
export default {
  async fetch(request, env) {
    const realm = env.REALM_CONTAINER.getByName("elixir-real-socket-integration");
    return realm.fetch(request);
  },
};
