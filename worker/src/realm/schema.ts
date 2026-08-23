/**
 * The proposal §7.2 block, verbatim. Additions required by the persistence
 * contract live in separate constants and init steps below this pinned block.
 */
export const SCHEMA_DDL = `CREATE TABLE logs (
  log_id         TEXT PRIMARY KEY,
  format_version INTEGER NOT NULL,
  revision       INTEGER NOT NULL DEFAULT 0,
  created_at     TEXT NOT NULL
) STRICT;

CREATE TABLE entries (
  arrival_seq    INTEGER PRIMARY KEY AUTOINCREMENT,
  log_id         TEXT NOT NULL,
  entry_id       TEXT NOT NULL,
  writer_id      TEXT NOT NULL,
  writer_seq     INTEGER NOT NULL,
  prev_entry_id  TEXT,
  created_at     TEXT NOT NULL,
  canonical_json BLOB NOT NULL,
  received_at_ms INTEGER NOT NULL,
  UNIQUE (log_id, entry_id),
  UNIQUE (log_id, writer_id, writer_seq)
) STRICT;

CREATE INDEX entries_by_log_writer
  ON entries (log_id, writer_id, writer_seq);

CREATE INDEX entries_by_log_arrival
  ON entries (log_id, arrival_seq);

CREATE TABLE writer_tips (
  log_id       TEXT NOT NULL,
  writer_id    TEXT NOT NULL,
  last_seq     INTEGER NOT NULL,
  last_entry_id TEXT NOT NULL,
  PRIMARY KEY (log_id, writer_id)
) STRICT;
`;

export const IMMUTABILITY_TRIGGERS = `CREATE TRIGGER IF NOT EXISTS entries_no_update
  BEFORE UPDATE ON entries
BEGIN
  SELECT RAISE(ABORT, 'entries are immutable');
END;

CREATE TRIGGER IF NOT EXISTS entries_no_delete
  BEFORE DELETE ON entries
BEGIN
  SELECT RAISE(ABORT, 'entries are immutable');
END;
`;

export const ENTRY_SIZE_TRIGGER = `CREATE TRIGGER IF NOT EXISTS entries_size_check
  BEFORE INSERT ON entries
  WHEN length(NEW.canonical_json) > 1048576
BEGIN
  SELECT RAISE(ABORT, 'entry is too large');
END;
`;

function hasTable(sql: SqlStorage, name: string): boolean {
  return sql
    .exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", name)
    .toArray().length > 0;
}

/** Apply the pinned layout, followed only by additive epoch and trigger DDL. */
export function initSchema(sql: SqlStorage): void {
  if (!hasTable(sql, "logs")) sql.exec(SCHEMA_DDL);

  const logColumns = sql.exec("PRAGMA table_info(logs)").toArray();
  if (!logColumns.some((column) => column.name === "lease_epoch")) {
    sql.exec("ALTER TABLE logs ADD COLUMN lease_epoch INTEGER NOT NULL DEFAULT 0");
  }

  sql.exec(IMMUTABILITY_TRIGGERS);
  sql.exec(ENTRY_SIZE_TRIGGER);
}
