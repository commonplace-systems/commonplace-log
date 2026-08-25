import proposal from "beam-native-revision.md?raw";
import { describe, expect, it } from "vitest";
import {
  DOCUMENT_WRITER_ID_COLUMN_DDL,
  IMMUTABILITY_TRIGGERS,
  SCHEMA_DDL,
  initSchema,
} from "../../src/realm/schema";
import { caught, withRealm } from "./helpers";

function proposalDdl(): string {
  const section = proposal.indexOf("### 7.2 Realm sidecar layout");
  const open = proposal.indexOf("```sql", section);
  const start = proposal.indexOf("\n", open) + 1;
  const close = proposal.indexOf("```", start);
  return proposal.slice(start, close).trim();
}

describe("realm section 7.2 schema on real DO SQLite", () => {
  it("keeps the illustrative section 7.2 DDL byte-for-byte", () => {
    expect(SCHEMA_DDL.trim()).toBe(proposalDdl());
  });

  it("creates all STRICT tables, both indexes, the epoch, and additive triggers", async () => {
    await withRealm((sql) => {
      expect(() => initSchema(sql)).not.toThrow();
      const objects = new Map(
        sql.exec("SELECT name, type, sql FROM sqlite_master").toArray().map((row) => [String(row.name), row]),
      );
      for (const table of ["logs", "entries", "writer_tips"]) {
        expect(objects.get(table)?.type).toBe("table");
        expect(String(objects.get(table)?.sql)).toContain("STRICT");
      }
      for (const index of ["entries_by_log_writer", "entries_by_log_arrival"])
        expect(objects.get(index)?.type).toBe("index");
      for (const trigger of ["entries_no_update", "entries_no_delete", "entries_size_check"])
        expect(objects.get(trigger)?.type).toBe("trigger");
      const columns = sql.exec("PRAGMA table_info(logs)").toArray().map((row) => String(row.name));
      expect(columns).toContain("lease_epoch");
      expect(columns).toContain("document_writer_id");
      expect(IMMUTABILITY_TRIGGERS).toContain("entries are immutable");
    });
  });

  it("is idempotent", async () => {
    await withRealm((sql) => {
      initSchema(sql);
      expect(() => initSchema(sql)).not.toThrow();
    });
  });

  it("idempotently migrates an existing pre-writer-column database without changing its rows", async () => {
    await withRealm((sql) => {
      sql.exec(SCHEMA_DDL);
      sql.exec("ALTER TABLE logs ADD COLUMN lease_epoch INTEGER NOT NULL DEFAULT 0");
      sql.exec(
        `INSERT INTO logs (log_id, format_version, revision, created_at, lease_epoch)
         VALUES ('existing', 7, 3, 'before-migration', 2)`,
      );

      initSchema(sql);
      expect(() => initSchema(sql)).not.toThrow();

      const columns = sql.exec("PRAGMA table_info(logs)").toArray();
      expect(columns.filter((row) => row.name === "document_writer_id")).toHaveLength(1);
      expect(columns.find((row) => row.name === "document_writer_id")).toMatchObject({
        type: "TEXT", notnull: 0,
      });
      expect(sql.exec(
        `SELECT log_id, format_version, revision, created_at, lease_epoch, document_writer_id
         FROM logs`,
      ).toArray()).toEqual([{
        log_id: "existing",
        format_version: 7,
        revision: 3,
        created_at: "before-migration",
        lease_epoch: 2,
        document_writer_id: null,
      }]);
      expect(DOCUMENT_WRITER_ID_COLUMN_DDL).toBe(
        "ALTER TABLE logs ADD COLUMN document_writer_id TEXT",
      );
    });
  });

  it("immutability UPDATE and DELETE errors have the observed workerd spelling", async () => {
    await withRealm((sql) => {
      initSchema(sql);
      sql.exec("INSERT INTO logs (log_id, format_version, revision, created_at) VALUES ('l', 1, 0, 'now')");
      sql.exec(`INSERT INTO entries
        (log_id, entry_id, writer_id, writer_seq, prev_entry_id, created_at, canonical_json, received_at_ms)
        VALUES ('l', 'e', 'w', 1, NULL, 'now', ?, 0)`, new Uint8Array([1]).buffer);
      expect((caught(() => sql.exec("UPDATE entries SET created_at = 'later'")) as Error).message)
        .toBe("entries are immutable: SQLITE_CONSTRAINT");
      expect((caught(() => sql.exec("DELETE FROM entries")) as Error).message)
        .toBe("entries are immutable: SQLITE_CONSTRAINT");
    });
  });

  it("rejects canonical_json larger than 1 MiB", async () => {
    await withRealm((sql) => {
      initSchema(sql);
      sql.exec("INSERT INTO logs (log_id, format_version, revision, created_at) VALUES ('l', 1, 0, 'now')");
      const error = caught(() => sql.exec(`INSERT INTO entries
        (log_id, entry_id, writer_id, writer_seq, prev_entry_id, created_at, canonical_json, received_at_ms)
        VALUES ('l', 'big', 'w', 1, NULL, 'now', ?, 0)`, new Uint8Array(1_048_577).buffer));
      expect((error as Error).message).toBe("entry is too large: SQLITE_CONSTRAINT");
    });
  });
});
