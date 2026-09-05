/** Administrative library only: no deployed entry, cron, or backup import. */
export interface ReconciliationEnv {
  REALMS: Pick<DurableObjectNamespace, "idFromName" | "get">;
  REALM_REGISTRY: Pick<KVNamespace, "list" | "delete"> & { get(key: string): Promise<string | null> };
}
export type CountObservation = { count: number; instrument: string };
export type Verdict = "present" | "absent" | "unknown";
export type RowResult = {
  realm_id: string;
  verdict: Verdict;
  cause: string;
  action: "keep" | "would_delete" | "deleted" | "delete_failed";
};
export type ReconciliationReport = {
  version: 1;
  mode: "dry_run" | "delete";
  registry_rows: number;
  registry_enumeration: "complete" | "unknown";
  stored_objects: CountObservation | null;
  count_cause: string | null;
  registry_minus_stored_objects: number | null;
  rows: RowResult[];
  removed: number;
  would_remove: number;
};
export type Options = {
  apply?: boolean;
  /** External lifecycle exclusion is an operator precondition, not a lock provided here. */
  lifecycleQuiesced?: boolean;
  timeoutMs?: number;
  countStoredObjects: () => Promise<CountObservation>;
};
const record = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value);

async function probe(env: ReconciliationEnv, realm: string, capability: string, timeoutMs: number): Promise<{ verdict: Verdict; cause: string }> {
  const abort = new AbortController();
  let timer: ReturnType<typeof setTimeout> | undefined;
  const read = async (): Promise<{ verdict: Verdict; cause: string }> => {
    try {
      const response = await env.REALMS.get(env.REALMS.idFromName(realm)).fetch("https://realm.internal/list-logs", {
        method: "POST", headers: { authorization: `Bearer ${capability}`, "content-type": "application/json" },
        body: JSON.stringify({ limit: 1 }), signal: abort.signal,
      });
      const text = await response.text();
      if (response.status >= 500) return { verdict: "unknown", cause: "http_5xx" };
      if (response.status === 401 || response.status === 403) return { verdict: "unknown", cause: "capability_rejected" };
      let body: unknown;
      try { body = JSON.parse(text); } catch { return { verdict: "unknown", cause: "malformed_body" }; }
      if (response.status === 404 && record(body) && body.ok === false && record(body.error) && body.error.code === "not_found") {
        return { verdict: "absent", cause: "not_found" };
      }
      if (response.status === 200 && record(body) && body.ok === true && Array.isArray(body.log_ids)
        && body.log_ids.every((id) => typeof id === "string")
        && (body.next_after_log_id === null || typeof body.next_after_log_id === "string")) {
        return { verdict: "present", cause: "read_ok" };
      }
      return { verdict: "unknown", cause: "unexpected_response" };
    } catch { return { verdict: "unknown", cause: "transport_error" }; }
  };
  try {
    return await Promise.race([read(), new Promise<{ verdict: Verdict; cause: string }>((resolve) => {
      timer = setTimeout(() => {
        resolve({ verdict: "unknown", cause: "timeout" });
        abort.abort();
      }, timeoutMs);
    })]);
  } finally { clearTimeout(timer); }
}

/** Returns a sensitive in-memory report. Caller must keep it inside approved custody. */
export async function reconcile(env: ReconciliationEnv, options: Options): Promise<ReconciliationReport> {
  const apply = options.apply === true;
  if (apply && options.lifecycleQuiesced !== true) throw new Error("lifecycle_quiescence_required");
  const timeoutMs = options.timeoutMs ?? 5000;
  if (!Number.isSafeInteger(timeoutMs) || timeoutMs < 1 || timeoutMs > 60000) throw new Error("invalid_timeout");
  const report: ReconciliationReport = {
    version: 1, mode: apply ? "delete" : "dry_run", registry_rows: 0, registry_enumeration: "unknown",
    stored_objects: null, count_cause: null, registry_minus_stored_objects: null,
    rows: [], removed: 0, would_remove: 0,
  };
  try {
    const observation = await options.countStoredObjects();
    if (!Number.isSafeInteger(observation.count) || observation.count < 0 || !observation.instrument) throw new Error("invalid_count");
    report.stored_objects = observation;
  } catch { report.count_cause = "stored_object_count_unavailable"; }
  const keys = new Set<string>();
  try {
    let cursor: string | undefined;
    const cursors = new Set<string>();
    for (;;) {
      const page = await env.REALM_REGISTRY.list({ cursor, limit: 100 });
      for (const key of page.keys) keys.add(key.name);
      if (page.list_complete) break;
      if (!page.cursor || cursors.has(page.cursor)) throw new Error("invalid_registry_cursor");
      cursors.add(page.cursor); cursor = page.cursor;
    }
    report.registry_enumeration = "complete";
  } catch {
    report.registry_rows = keys.size;
    report.rows = [...keys].map((realm_id) => ({ realm_id, verdict: "unknown", cause: "registry_enumeration_failed", action: "keep" }));
    return report; // A partial listing is not a deletion plan.
  }
  report.registry_rows = keys.size;
  if (report.stored_objects !== null) report.registry_minus_stored_objects = keys.size - report.stored_objects.count;
  for (const realm_id of keys) {
    const row: RowResult = { realm_id, verdict: "unknown", cause: "registry_read_failed", action: "keep" };
    report.rows.push(row);
    let raw: string | null;
    try { raw = await env.REALM_REGISTRY.get(realm_id); } catch { continue; }
    if (raw === null) { row.cause = "registry_row_missing"; continue; }
    let value: unknown;
    try { value = JSON.parse(raw); } catch { row.cause = "invalid_registry_row"; continue; }
    if (!record(value) || value.realm_id !== realm_id || typeof value.read_capability !== "string"
      || !/^[0-9a-f]{64}$/.test(value.read_capability)) { row.cause = "invalid_registry_row"; continue; }
    Object.assign(row, await probe(env, realm_id, value.read_capability, timeoutMs));
    if (row.verdict !== "absent") continue;
    if (!apply) { row.action = "would_delete"; report.would_remove++; continue; }
    // This is NOT compare-and-delete. Requires external lifecycle quiescence;
    // REGISTRY-SELF-DELETE-1 will move deletion under the DO's lifecycle gate.
    let current: string | null;
    try { current = await env.REALM_REGISTRY.get(realm_id); }
    catch { row.verdict = "unknown"; row.cause = "registry_recheck_failed"; continue; }
    if (current !== raw) { row.verdict = "unknown"; row.cause = "registry_row_changed"; continue; }
    try { await env.REALM_REGISTRY.delete(realm_id); row.action = "deleted"; report.removed++; }
    catch { row.action = "delete_failed"; row.cause = "registry_delete_failed"; }
  }
  return report;
}
