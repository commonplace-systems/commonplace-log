/** Read-only realm HTTP client. Checkpoints advance only after durable entry objects. */
export interface BackupEnv {
  REALMS: Pick<DurableObjectNamespace, "idFromName" | "get">;
  // Only these KV operations enter the loop. A KV binding itself is not a platform read-only grant.
  REALM_REGISTRY: Pick<KVNamespace, "get" | "list">;
  BACKUP: Pick<R2Bucket, "get" | "put">;
}

type ReadRoute = "/list-logs" | "/frontier" | "/read-writer";
type Tip = { writer_id: string; seq: number; entry_id: string };
type Checkpoint = { version: 1; log_id: string; writers: Tip[] };
type StopCode = "registry_invalid" | "registry_entry_missing" | "registry_unavailable"
  | "capability_rejected" | "realm_not_found" | "read_refused" | "read_failed"
  | "invalid_response" | "source_regressed" | "writer_fork" | "backup_entry_conflict"
  | "checkpoint_conflict" | "storage_failed";
class Stop extends Error {
  constructor(readonly code: StopCode) { super(code); }
}
export type RealmResult = {
  realm_id: string;
  entries_appended: number;
  frontiers_written: string[];
  manifest_written: boolean;
  outcome: "complete" | "stopped";
  stop?: StopCode;
};
export type RunResult = {
  version: 1;
  run_id: string;
  started_at: string;
  completed_at: string;
  enumeration: "registry_only";
  coverage: "registered_realms_only";
  registry_count: number;
  realms: RealmResult[];
  outcome: "complete" | "stopped";
  stop?: StopCode;
};
const PAGE_SIZE = 100;
const segment = (value: string) => encodeURIComponent(value);
const prefix = (realm: string, log: string) => `${segment(realm)}/${segment(log)}`;

function object(value: unknown): Record<string, unknown> {
  if (typeof value !== "object" || value === null || Array.isArray(value)) throw new Stop("invalid_response");
  return value as Record<string, unknown>;
}
function identifier(value: unknown): string {
  if (typeof value !== "string" || value.length === 0) throw new Stop("invalid_response");
  return value;
}
function array(value: unknown): unknown[] {
  if (!Array.isArray(value)) throw new Stop("invalid_response");
  return value;
}
function sequence(value: unknown): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < 1) throw new Stop("invalid_response");
  return value;
}
function tips(value: unknown): Tip[] {
  const seen = new Set<string>();
  return array(value).map((item) => {
    const row = object(item);
    const writer_id = identifier(row.writer_id);
    if (seen.has(writer_id)) throw new Stop("invalid_response");
    seen.add(writer_id);
    return { writer_id, seq: sequence(row.seq), entry_id: identifier(row.entry_id) };
  }).sort((a, b) => a.writer_id < b.writer_id ? -1 : a.writer_id > b.writer_id ? 1 : 0);
}

async function read(env: BackupEnv, realm: string, capability: string, route: ReadRoute,
  body: Record<string, unknown>): Promise<Record<string, unknown>> {
  let response: Response;
  try {
    response = await env.REALMS.get(env.REALMS.idFromName(realm)).fetch(
      `https://realm.internal${route}`, {
        method: "POST", headers: { authorization: `Bearer ${capability}`, "content-type": "application/json" },
        body: JSON.stringify(body),
      },
    );
  } catch { throw new Stop("read_failed"); }
  // Never copy error bodies or thrown messages: they may include request credentials.
  if (!response.ok) {
    // Finish the cross-Worker stream before releasing its storage/test context.
    try { await response.arrayBuffer(); } catch { throw new Stop("read_failed"); }
  }
  if (response.status === 401 || response.status === 403) throw new Stop("capability_rejected");
  if (response.status === 404) throw new Stop("realm_not_found");
  if (!response.ok) throw new Stop("read_refused");
  try {
    const result = object(await response.json());
    if (result.ok !== true) throw new Stop("invalid_response");
    return result;
  } catch { throw new Stop("invalid_response"); }
}

async function listLogs(env: BackupEnv, realm: string, capability: string): Promise<string[]> {
  const logs: string[] = [];
  let after = "";
  for (;;) {
    const page = await read(env, realm, capability, "/list-logs", { after_log_id: after, limit: PAGE_SIZE });
    const ids = array(page.log_ids).map(identifier);
    for (const id of ids) {
      if (id <= after) throw new Stop("invalid_response");
      logs.push(id); after = id;
    }
    if (page.next_after_log_id === null) return logs;
    if (ids.length === 0 || page.next_after_log_id !== after) throw new Stop("invalid_response");
  }
}

async function stored(env: BackupEnv, key: string): Promise<{ text: string; etag: string } | null> {
  try {
    const item = await env.BACKUP.get(key);
    return item === null ? null : { text: await item.text(), etag: item.etag };
  } catch { throw new Stop("storage_failed"); }
}

/** Conditional checkpoints prevent an overlapping stale run from replacing a newer snapshot. */
async function checkpoint(env: BackupEnv, key: string, value: unknown,
  previous: { text: string; etag: string } | null): Promise<boolean> {
  const text = JSON.stringify(value);
  if (previous?.text === text) return false;
  try {
    const saved = await env.BACKUP.put(key, text, {
      onlyIf: previous === null ? { etagDoesNotMatch: "*" } : { etagMatches: previous.etag },
      httpMetadata: { contentType: "application/json" },
    });
    if (saved === null) throw new Stop("checkpoint_conflict");
    return true;
  } catch (error) {
    if (error instanceof Stop) throw error;
    throw new Stop("storage_failed");
  }
}

async function appendObject(env: BackupEnv, key: string, bytes: Uint8Array): Promise<boolean> {
  try {
    // If-None-Match is atomic: concurrent runs cannot overwrite an immutable entry.
    const written = await env.BACKUP.put(key, bytes, {
      onlyIf: { etagDoesNotMatch: "*" }, httpMetadata: { contentType: "application/json" },
    });
    if (written !== null) return true;
    const existing = await env.BACKUP.get(key);
    if (existing === null) throw new Stop("storage_failed");
    const prior = new Uint8Array(await existing.arrayBuffer());
    if (prior.length !== bytes.length || prior.some((byte, i) => byte !== bytes[i])) {
      throw new Stop("backup_entry_conflict");
    }
    return false;
  } catch (error) {
    if (error instanceof Stop) throw error;
    throw new Stop("storage_failed");
  }
}

function decode(encoded: unknown): { bytes: Uint8Array; entry: Record<string, unknown> } {
  try {
    const bytes = Uint8Array.from(atob(identifier(encoded)), (ch) => ch.charCodeAt(0));
    return { bytes, entry: object(JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes))) };
  } catch { throw new Stop("invalid_response"); }
}

async function backupLog(env: BackupEnv, realm: string, capability: string, log: string,
  result: RealmResult): Promise<void> {
  const key = `${prefix(realm, log)}/frontier.json`;
  const previous = await stored(env, key);
  let prior: Tip[] = [];
  if (previous !== null) {
    try {
      const value = object(JSON.parse(previous.text));
      if (value.version !== 1 || value.log_id !== log) throw new Stop("invalid_response");
      prior = tips(value.writers);
    } catch { throw new Stop("invalid_response"); }
  }
  const response = await read(env, realm, capability, "/frontier", { log_id: log });
  const current = tips(object(response.frontier).writers);
  const old = new Map(prior.map((tip) => [tip.writer_id, tip]));
  for (const tip of prior) {
    const next = current.find((item) => item.writer_id === tip.writer_id);
    if (next === undefined || next.seq < tip.seq) throw new Stop("source_regressed");
    if (next.seq === tip.seq && next.entry_id !== tip.entry_id) throw new Stop("writer_fork");
  }
  for (const tip of current) {
    const last = old.get(tip.writer_id);
    let after = last?.seq ?? 0;
    let predecessor: string | null = last?.entry_id ?? null;
    while (after < tip.seq) {
      const response = await read(env, realm, capability, "/read-writer", {
        log_id: log, writer_id: tip.writer_id, after_seq: after, through_seq: tip.seq, limit: PAGE_SIZE,
      });
      const page = object(response.page);
      const rows = array(page.entries);
      if (rows.length === 0 || rows.length > PAGE_SIZE) throw new Stop("invalid_response");
      for (const item of rows) {
        const row = object(item);
        const { bytes, entry } = decode(row.canonical_bytes);
        if (row.writer_seq !== after + 1 || entry.writer_seq !== row.writer_seq || row.writer_seq > tip.seq
          || entry.log_id !== log || entry.writer_id !== tip.writer_id) throw new Stop("invalid_response");
        if (entry.prev_entry_id !== predecessor) throw new Stop("writer_fork");
        const id = identifier(entry.entry_id);
        if (row.writer_seq === tip.seq && id !== tip.entry_id) throw new Stop("writer_fork");
        const objectKey = `${prefix(realm, log)}/${segment(tip.writer_id)}/${String(row.writer_seq).padStart(12, "0")}.json`;
        if (await appendObject(env, objectKey, bytes)) result.entries_appended++;
        after = row.writer_seq; predecessor = id;
      }
      if (after < tip.seq && page.next_after_seq !== after) throw new Stop("invalid_response");
      if (after === tip.seq && page.next_after_seq !== null) throw new Stop("invalid_response");
    }
  }
  const value: Checkpoint = { version: 1, log_id: log, writers: current };
  // Commit point for this log: every entry through these tips exists in R2 before this put.
  if (await checkpoint(env, key, value, previous)) result.frontiers_written.push(log);
}

async function backupRealm(env: BackupEnv, realm: string, capability: string, result: RealmResult) {
  const manifestKey = `${segment(realm)}/manifest.json`;
  const previous = await stored(env, manifestKey);
  const logs = await listLogs(env, realm, capability);
  if (previous !== null) {
    try {
      const manifest = object(JSON.parse(previous.text));
      if (manifest.version !== 1 || manifest.realm_id !== realm) throw new Stop("invalid_response");
      if (array(manifest.log_ids).map(identifier).some((log) => !logs.includes(log))) throw new Stop("source_regressed");
    } catch (error) { if (error instanceof Stop) throw error; throw new Stop("invalid_response"); }
  }
  for (const log of logs) await backupLog(env, realm, capability, log, result);
  // Realm commit point: inventory appears only once each named log has a durable frontier.
  result.manifest_written = await checkpoint(env, manifestKey,
    { version: 1, realm_id: realm, log_ids: logs }, previous);
}

export async function runBackup(env: BackupEnv): Promise<RunResult> {
  const run: RunResult = {
    version: 1, run_id: crypto.randomUUID(), started_at: new Date().toISOString(), completed_at: "",
    enumeration: "registry_only", coverage: "registered_realms_only", registry_count: 0,
    realms: [], outcome: "complete",
  };
  let cursor: string | undefined;
  const seen = new Set<string>();
  try {
    for (;;) {
      const page = await env.REALM_REGISTRY.list({ cursor, limit: PAGE_SIZE });
      for (const key of page.keys) {
        if (seen.has(key.name)) continue;
        seen.add(key.name); run.registry_count++;
        const result: RealmResult = { realm_id: key.name, entries_appended: 0, frontiers_written: [],
          manifest_written: false, outcome: "complete" };
        run.realms.push(result);
        try {
          const raw = await env.REALM_REGISTRY.get(key.name);
          if (raw === null) throw new Stop("registry_entry_missing");
          let value: Record<string, unknown>;
          try { value = object(JSON.parse(raw)); } catch { throw new Stop("registry_invalid"); }
          if (value.realm_id !== key.name || typeof value.read_capability !== "string"
            || !/^[0-9a-f]{64}$/.test(value.read_capability)) throw new Stop("registry_invalid");
          await backupRealm(env, key.name, value.read_capability, result);
        } catch (error) {
          result.outcome = "stopped";
          result.stop = error instanceof Stop ? error.code : "registry_unavailable";
          run.outcome = "stopped";
        }
      }
      if (page.list_complete) break;
      if (!page.cursor || page.cursor === cursor) throw new Stop("registry_unavailable");
      cursor = page.cursor;
    }
  } catch {
    run.outcome = "stopped"; run.stop = "registry_unavailable";
  }
  run.completed_at = new Date().toISOString();
  // If even the run log cannot be persisted, reject the invocation; never claim success.
  if (!await env.BACKUP.put(`_runs/${run.run_id}.json`, JSON.stringify(run), {
    onlyIf: { etagDoesNotMatch: "*" }, httpMetadata: { contentType: "application/json" },
  })) throw new Stop("storage_failed");
  return run;
}
