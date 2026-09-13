import { RealmContainer } from "../src/realm/container.ts";

export { RealmContainer };

const TARGET = "elixir-log-inventory-integration";
const ALLOWED = new Set([
  "/realm/create",
  "/list-logs",
  "/restore-bundle-batch",
  "/create-log",
  "/take-lease",
  "/commit",
  "/read-writer",
]);

async function consumeCreateBody(request) {
  if (request.body === null) return false;
  const reader = request.body.getReader();
  const chunks = [];
  let total = 0;
  try {
    while (true) {
      const next = await reader.read();
      if (next.done) break;
      total += next.value.byteLength;
      if (total > 64) {
        try { await reader.cancel(); } catch { /* preserve malformed result */ }
        return false;
      }
      chunks.push(next.value);
    }
  } finally {
    reader.releaseLock();
  }
  const body = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    body.set(chunk, offset);
    offset += chunk.byteLength;
  }
  try {
    return new TextDecoder("utf-8", { fatal: true }).decode(body) === "{}";
  } catch {
    return false;
  }
}

function bodylessCreate(request) {
  const headers = new Headers(request.headers);
  headers.delete("content-length");
  headers.delete("transfer-encoding");
  return new Request(request.url, { method: request.method, headers });
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const realm = env.REALM_CONTAINER.getByName(TARGET);
    if (request.method !== "POST" || !ALLOWED.has(url.pathname)) {
      return Response.json({ ok: false, error: { code: "not_found" } }, { status: 404 });
    }
    if (url.pathname === "/realm/create") {
      if (!(await consumeCreateBody(request))) {
        return Response.json({ ok: false, error: { code: "malformed_request" } }, { status: 400 });
      }
      return realm.fetch(bodylessCreate(request));
    }
    return realm.storageFetch(request);
  },
};
