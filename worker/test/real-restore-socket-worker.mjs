import { RealmContainer } from "../src/realm/container.ts";

export { RealmContainer };

const TARGET = "elixir-real-socket-integration";
const ALLOWED = new Set([
  "/realm/create",
  "/create-log",
  "/take-lease",
  "/read-writer",
  "/restore-bundle-batch",
]);

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const realm = env.REALM_CONTAINER.getByName(TARGET);
    if (request.method !== "POST" || !ALLOWED.has(url.pathname)) {
      return Response.json({ ok: false, error: { code: "not_found" } }, { status: 404 });
    }
    if (url.pathname === "/realm/create") return realm.fetch(request);
    return realm.storageFetch(request);
  },
};
