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

/** Durable single-lane identity, additive to the pinned proposal layout. */
export const DOCUMENT_WRITER_ID_COLUMN_DDL =
  "ALTER TABLE logs ADD COLUMN document_writer_id TEXT";

/** Realm existence and authorization, additive to the pinned proposal layout. */
export const REALM_META_DDL = `CREATE TABLE realm_meta (
  singleton   INTEGER PRIMARY KEY CHECK (singleton = 1),
  secret_hash BLOB NOT NULL CHECK (length(secret_hash) = 32),
  created_at  TEXT NOT NULL,
  read_secret_hash BLOB CHECK (read_secret_hash IS NULL OR length(read_secret_hash) = 32),
  read_created_at TEXT
) STRICT;`;

/** Operator-owned idempotent realm allocation identity; no plaintext secret is stored. */
export const REALM_ALLOCATIONS_DDL = `CREATE TABLE realm_allocations (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  realm_id TEXT NOT NULL, operation_id TEXT NOT NULL,
  operation_hash BLOB NOT NULL CHECK (length(operation_hash) = 32),
  secret_hash BLOB NOT NULL CHECK (length(secret_hash) = 32),
  capability_hash BLOB NOT NULL CHECK (length(capability_hash) = 32), created_at TEXT NOT NULL
) STRICT;`;

export const RESTORE_MARKERS_DDL = `CREATE TABLE IF NOT EXISTS restore_markers (
  log_id TEXT PRIMARY KEY,
  archive_id TEXT NOT NULL,
  writer_id TEXT NOT NULL,
  entry_count INTEGER NOT NULL,
  total_bytes INTEGER NOT NULL,
  manifest_json BLOB NOT NULL,
  state TEXT NOT NULL CHECK (state IN ('pending', 'complete'))
) STRICT;`;

/** Internal provider-local bundle inventory. The digest is compact; entries remain in entries. */
export const RESTORE_BUNDLES_DDL = `CREATE TABLE IF NOT EXISTS restore_bundles (
  singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
  bundle_id TEXT NOT NULL,
  log_count INTEGER NOT NULL,
  digest BLOB NOT NULL CHECK (length(digest) = 32),
  state TEXT NOT NULL CHECK (state IN ('pending', 'complete'))
) STRICT;

CREATE TABLE IF NOT EXISTS restore_bundle_logs (
  bundle_id TEXT NOT NULL,
  log_id TEXT PRIMARY KEY,
  archive_id TEXT NOT NULL,
  writer_id TEXT NOT NULL,
  entry_count INTEGER NOT NULL,
  total_bytes INTEGER NOT NULL,
  digest BLOB NOT NULL CHECK (length(digest) = 32),
  state TEXT NOT NULL CHECK (state IN ('pending', 'complete'))
) STRICT;`;

function hasTable(sql: SqlStorage, name: string): boolean {
  return sql
    .exec("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ?", name)
    .toArray().length > 0;
}

export function initRealmAllocationSchema(sql: SqlStorage): void {
  initRealmMetaSchema(sql);
  if (!hasTable(sql, "realm_allocations")) sql.exec(REALM_ALLOCATIONS_DDL);
  const columns = sql.exec("PRAGMA table_info(realm_allocations)").toArray();
  if (!columns.some((column) => column.name === "capability_hash")) sql.exec("ALTER TABLE realm_allocations ADD COLUMN capability_hash BLOB");
}

export function initRealmMetaSchema(sql: SqlStorage): void {
  if (!hasTable(sql, "realm_meta")) sql.exec(REALM_META_DDL);
  const columns = sql.exec("PRAGMA table_info(realm_meta)").toArray();
  if (!columns.some((column) => column.name === "read_secret_hash")) sql.exec("ALTER TABLE realm_meta ADD COLUMN read_secret_hash BLOB");
  if (!columns.some((column) => column.name === "read_created_at")) sql.exec("ALTER TABLE realm_meta ADD COLUMN read_created_at TEXT");
}

/** Apply the pinned layout, followed only by additive epoch and trigger DDL. */
export function initSchema(sql: SqlStorage): void {
  if (!hasTable(sql, "logs")) sql.exec(SCHEMA_DDL);

  const logColumns = sql.exec("PRAGMA table_info(logs)").toArray();
  if (!logColumns.some((column) => column.name === "lease_epoch")) {
    sql.exec("ALTER TABLE logs ADD COLUMN lease_epoch INTEGER NOT NULL DEFAULT 0");
  }
  if (!logColumns.some((column) => column.name === "document_writer_id")) {
    sql.exec(DOCUMENT_WRITER_ID_COLUMN_DDL);
  }

  sql.exec(IMMUTABILITY_TRIGGERS);
  sql.exec(ENTRY_SIZE_TRIGGER);
  initRealmMetaSchema(sql);
  sql.exec(RESTORE_MARKERS_DDL);
  sql.exec(RESTORE_BUNDLES_DDL);
}
