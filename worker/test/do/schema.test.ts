import { env, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
// Inlined at transform time by vite (aliased in vitest.workers.config.ts);
// workerd has no filesystem, so the raw import is the only way the test can
// see the spec document.
import specText from "commonplace-monotonic-log-spec.md?raw";
import { IMMUTABILITY_TRIGGERS, SCHEMA_DDL, initSchema } from "../../src/do/schema";

/**
 * SP2 Task 2: §12 schema + jes-approved immutability triggers.
 *
 * The DDL is pinned verbatim in the spec; `SCHEMA_DDL` must be a byte-for-byte
 * copy (the fidelity gate below makes transcription drift detectable). The
 * triggers are an ADDITION executed after the DDL and must never require
 * altering any pinned column, constraint, or index.
 */

/** Run `fn` against a fresh Durable Object's real SQLite storage. */
async function withSql<T>(fn: (sql: SqlStorage) => T): Promise<T> {
  const stub = env.COMMONPLACE_LOG.get(env.COMMONPLACE_LOG.idFromName("schema-test"));
  return await runInDurableObject(stub, (_instance, state) => fn(state.storage.sql));
}

/** Insert a minimal STRICT-satisfying row into `entries` (direct SQL is fine at this layer). */
function insertEntry(sql: SqlStorage, entryId: string, writerSeq: number): void {
  sql.exec(
    `INSERT INTO entries
       (entry_id, writer_id, writer_seq, prev_entry_id, created_at, canonical_json, received_at_ms)
     VALUES (?, ?, ?, ?, ?, ?, ?)`,
    entryId,
    "fab4e8a5-ce9e-48d0-8f78-1d312b978207",
    writerSeq,
    writerSeq === 1 ? null : `entry-${writerSeq - 1}`,
    "2026-08-22T00:00:00Z",
    new TextEncoder().encode(`{"n":${writerSeq}}`).buffer,
    1_766_000_000_000,
  );
}

/** name -> {type, sql} for everything in sqlite_master. */
function schemaObjects(sql: SqlStorage): Map<string, { type: string; sql: string | null }> {
  const rows = sql.exec("SELECT name, type, sql FROM sqlite_master").toArray();
  return new Map(rows.map((r) => [String(r.name), { type: String(r.type), sql: r.sql === null ? null : String(r.sql) }]));
}

describe("§12 schema DDL fidelity gate (copy, don't retype)", () => {
  /** Strip trailing whitespace per line — the ONLY normalization permitted. */
  const norm = (s: string): string =>
    s
      .split("\n")
      .map((line) => line.replace(/[ \t]+$/, ""))
      .join("\n");

  /** Extract the individual SQL statements of the §12 ```sql block from the spec. */
  function extractSection12Statements(spec: string): string[] {
    const heading = spec.indexOf("## 12. SQLite storage layout");
    expect(heading).toBeGreaterThanOrEqual(0);
    const fenceOpen = spec.indexOf("```sql", heading);
    expect(fenceOpen).toBeGreaterThanOrEqual(0);
    const bodyStart = spec.indexOf("\n", fenceOpen) + 1;
    const fenceClose = spec.indexOf("```", bodyStart);
    expect(fenceClose).toBeGreaterThan(bodyStart);
    const block = spec.slice(bodyStart, fenceClose);
    // No statement in the pinned DDL contains an interior semicolon.
    return block
      .split(";")
      .map((s) => s.replace(/^\s*\n/, "").replace(/\s+$/, ""))
      .filter((s) => s.length > 0)
      .map((s) => `${s};`);
  }

  it("SCHEMA_DDL contains each of the four §12 statements exactly", () => {
    const statements = extractSection12Statements(specText);

    // Anti-vacuity floor: an empty or partial extraction must fail loudly
    // before any containment check can vacuously pass.
    expect(statements).toHaveLength(4);
    const expectedObjects = ["log_meta", "entries", "entries_by_writer", "writer_tips"];
    for (const [i, name] of expectedObjects.entries()) {
      expect(statements[i]).toContain(name);
    }

    for (const statement of statements) {
      expect(norm(SCHEMA_DDL)).toContain(norm(statement));
    }
  });

  it("SCHEMA_DDL equals the whole §12 block — no fifth statement can hide", () => {
    const heading = specText.indexOf("## 12. SQLite storage layout");
    const fenceOpen = specText.indexOf("```sql", heading);
    const bodyStart = specText.indexOf("\n", fenceOpen) + 1;
    const fenceClose = specText.indexOf("```", bodyStart);
    const block = specText.slice(bodyStart, fenceClose);
    // Whole-block equality: containment alone would let SCHEMA_DDL grow
    // statements the spec does not pin.
    expect(norm(SCHEMA_DDL).trim()).toBe(norm(block).trim());
  });

  it("control: a deliberately perturbed statement does NOT match (the gate can fire)", () => {
    const statements = extractSection12Statements(specText);
    expect(statements).toHaveLength(4);
    const entriesTable = statements[1]!;
    const perturbed = entriesTable.replace("canonical_json BLOB NOT NULL", "canonical_json TEXT NOT NULL");
    // Prove the perturbation actually changed the statement…
    expect(perturbed).not.toBe(entriesTable);
    // …and that the gate rejects it: containment is not vacuous.
    expect(norm(SCHEMA_DDL)).not.toContain(norm(perturbed));
  });
});

describe("initSchema", () => {
  it("creates the three STRICT tables and the entries_by_writer index (verified via sqlite_master)", async () => {
    await withSql((sql) => {
      initSchema(sql);
      const objects = schemaObjects(sql);

      for (const table of ["log_meta", "entries", "writer_tips"]) {
        const obj = objects.get(table);
        expect(obj, `table ${table} missing from sqlite_master`).toBeDefined();
        expect(obj!.type).toBe("table");
        expect(obj!.sql, `table ${table} must be STRICT`).toContain("STRICT");
      }

      const index = objects.get("entries_by_writer");
      expect(index, "index entries_by_writer missing from sqlite_master").toBeDefined();
      expect(index!.type).toBe("index");
      expect(index!.sql).toContain("ON entries (writer_id, writer_seq)");
    });
  });

  it("is idempotent: re-running initSchema is a no-op and preserves existing data", async () => {
    await withSql((sql) => {
      initSchema(sql);
      insertEntry(sql, "entry-1", 1);

      expect(() => initSchema(sql)).not.toThrow();

      const objects = schemaObjects(sql);
      for (const name of ["log_meta", "entries", "writer_tips", "entries_by_writer"]) {
        expect(objects.has(name), `${name} missing after re-init`).toBe(true);
      }
      const count = sql.exec("SELECT COUNT(*) AS n FROM entries").one();
      expect(Number(count.n)).toBe(1);
    });
  });

  it("installs both immutability triggers (entries_no_update, entries_no_delete)", async () => {
    await withSql((sql) => {
      initSchema(sql);
      const objects = schemaObjects(sql);
      for (const trigger of ["entries_no_update", "entries_no_delete"]) {
        const obj = objects.get(trigger);
        expect(obj, `trigger ${trigger} missing from sqlite_master`).toBeDefined();
        expect(obj!.type).toBe("trigger");
        expect(obj!.sql).toContain("entries are immutable");
      }
      // The triggers const itself must be IF NOT EXISTS so re-init stays idempotent.
      expect(IMMUTABILITY_TRIGGERS).toContain("CREATE TRIGGER IF NOT EXISTS entries_no_update");
      expect(IMMUTABILITY_TRIGGERS).toContain("CREATE TRIGGER IF NOT EXISTS entries_no_delete");
    });
  });
});

describe("immutability trigger red paths (the recorded artifact)", () => {
  it("UPDATE on a committed entry raises: error text contains 'entries are immutable'", async () => {
    await withSql((sql) => {
      initSchema(sql);
      insertEntry(sql, "entry-1", 1);

      let caught: unknown;
      try {
        sql.exec("UPDATE entries SET created_at = 'x' WHERE entry_id = 'entry-1'");
      } catch (error) {
        caught = error;
      }

      expect(caught).toBeInstanceOf(Error);
      const message = (caught as Error).message;
      // Full observed error text (workerd DO SQLite, recorded 2026-08-22):
      //   "entries are immutable: SQLITE_CONSTRAINT"
      expect(message).toContain("entries are immutable");

      // Verify by effect: the row is untouched.
      const row = sql.exec("SELECT created_at FROM entries WHERE entry_id = 'entry-1'").one();
      expect(row.created_at).toBe("2026-08-22T00:00:00Z");
    });
  });

  it("DELETE on a committed entry raises: error text contains 'entries are immutable'", async () => {
    await withSql((sql) => {
      initSchema(sql);
      insertEntry(sql, "entry-1", 1);

      let caught: unknown;
      try {
        sql.exec("DELETE FROM entries WHERE entry_id = 'entry-1'");
      } catch (error) {
        caught = error;
      }

      expect(caught).toBeInstanceOf(Error);
      const message = (caught as Error).message;
      // Full observed error text (workerd DO SQLite, recorded 2026-08-22):
      //   "entries are immutable: SQLITE_CONSTRAINT"
      expect(message).toContain("entries are immutable");

      // Verify by effect: the row survived.
      const count = sql.exec("SELECT COUNT(*) AS n FROM entries").one();
      expect(Number(count.n)).toBe(1);
    });
  });

  it("INSERT into entries still works after the triggers exist", async () => {
    await withSql((sql) => {
      initSchema(sql);
      insertEntry(sql, "entry-1", 1);
      insertEntry(sql, "entry-2", 2);
      const count = sql.exec("SELECT COUNT(*) AS n FROM entries").one();
      expect(Number(count.n)).toBe(2);
    });
  });

  it("does not overreach: UPDATE and DELETE on writer_tips still work", async () => {
    await withSql((sql) => {
      initSchema(sql);
      sql.exec(
        "INSERT INTO writer_tips (writer_id, last_seq, last_entry_id) VALUES (?, ?, ?)",
        "fab4e8a5-ce9e-48d0-8f78-1d312b978207",
        1,
        "entry-1",
      );

      sql.exec(
        "UPDATE writer_tips SET last_seq = 2, last_entry_id = 'entry-2' WHERE writer_id = ?",
        "fab4e8a5-ce9e-48d0-8f78-1d312b978207",
      );
      const row = sql.exec("SELECT last_seq, last_entry_id FROM writer_tips").one();
      expect(Number(row.last_seq)).toBe(2);
      expect(row.last_entry_id).toBe("entry-2");

      sql.exec("DELETE FROM writer_tips WHERE writer_id = ?", "fab4e8a5-ce9e-48d0-8f78-1d312b978207");
      const count = sql.exec("SELECT COUNT(*) AS n FROM writer_tips").one();
      expect(Number(count.n)).toBe(0);
    });
  });
});
