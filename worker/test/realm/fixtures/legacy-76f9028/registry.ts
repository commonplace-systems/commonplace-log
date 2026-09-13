/**
 * The realm registry — the only thing standing between "backed up everything" and
 * "backed up everything I happened to know about".
 *
 * ⛔⛔ MEASURED 2026-09-04 (BACKUP-1a): REALMS CAN BE COUNTED AND CANNOT BE NAMED.
 *   The Durable Object objects listing returns exactly `{ id, hasStoredData }` — no name — and a
 *   realm's object id is `idFromName(realmId)`, a ONE-WAY derivation. There is no registry, index
 *   or catalog anywhere in `worker/src`. ⇒ NOTHING in the platform or in this code can enumerate
 *   the realms that exist, so a backup can only walk realms it was TOLD about.
 *
 * ⭐ THE COUNT IS THIS REGISTRY'S CONTROL. The objects listing cannot name realms but it can COUNT
 *   them, so `registry entries == RealmNode objects with stored data` is a check in a DIFFERENT
 *   system that must agree with this one. ⛔ Without it, a realm created by a path that forgets to
 *   register is invisible to the backup AND to every check of the backup — silent at both ends.
 *
 * ⛔ CUSTODY: this holds READ capabilities only. The write secret is generated in `create`,
 *   returned to the caller once, and NEVER written here. The read capability is minted in the same
 *   act and is NOT returned over the wire — it goes to the registry and nowhere else.
 */

/** The registry's write side. Implemented over KV in production; a fake in tests. */
export interface RealmRegistry {
  put(realmId: string, readCapability: string): Promise<void>;
  delete(realmId: string): Promise<void>;
}

/**
 * Registry outcomes: registration is ALWAYS reported in the create response;
 * removal failures are reported in the error response (successful removal is empty 204).
 *
 * ⭐⭐ EVERY OUTCOME IS NAMED AND NONE IS SILENT. A realm that is created but not registered is
 * exactly the state the count control exists to catch, and the caller learns it at the moment it
 * happens rather than a day later from a backup that was quietly short.
 */
export type RegistryOutcome =
  | "registered"
  | "no_registry_bound"
  | "already_minted"
  | "registry_write_failed"
  | "deleted"
  | "registry_delete_failed";

/** Adapt a KV namespace to the registry interface; `undefined` when the binding is absent. */
export function kvRegistry(kv: KVNamespace | undefined): RealmRegistry | undefined {
  if (kv === undefined) return undefined;
  return {
    async delete(realmId) {
      await kv.delete(realmId);
    },
    async put(realmId, readCapability) {
      await kv.put(realmId, JSON.stringify({
        realm_id: realmId,
        read_capability: readCapability,
        registered_at: new Date().toISOString(),
      }));
    },
  };
}
