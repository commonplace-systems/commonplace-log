import { env, runInDurableObject } from "cloudflare:test";
import { RealmStore } from "../../src/realm/store";

let sequence = 0;

export async function withRealm<T>(fn: (sql: SqlStorage, store: RealmStore) => T): Promise<T> {
  const name = `realm-test-${Date.now()}-${sequence++}`;
  const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName(name));
  return await runInDurableObject(stub, (_instance, state) =>
    fn(state.storage.sql, new RealmStore(state.storage.sql, state.storage)),
  );
}

export function bytes(value: string): Uint8Array {
  return new TextEncoder().encode(value);
}

export function decoded(value: Uint8Array): string {
  return new TextDecoder().decode(value);
}

export function caught(fn: () => unknown): unknown {
  try {
    fn();
  } catch (error) {
    return error;
  }
  return undefined;
}
