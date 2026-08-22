defmodule Commonplace.LogStore.SQLite.Schema do
  @moduledoc """
  SP3 Task 1: the §12 SQLite storage layout for the local Elixir adapter —
  the twin of `worker/src/do/schema.ts` (SP2 Task 2).

  `ddl/0` is copied BYTE-FOR-BYTE from the ```sql block of
  `docs/commonplace-monotonic-log-spec.md` §12 (extracted by script, not
  retyped). Do not reformat or "improve" it — the fidelity gate in
  `test/sqlite_schema_test.exs` compares it against the spec file and fails
  on any drift.

  The immutability triggers are a jes-approved ADDITION (SP2 plan, design
  decision Q3; carried into SP3 unchanged), executed AFTER the verbatim DDL
  in the same init step. They guard UPDATE and DELETE on `entries` only;
  INSERT stays open, and other tables are untouched.
  """

  alias Exqlite.Sqlite3

  @ddl """
  CREATE TABLE IF NOT EXISTS log_meta (
    singleton      INTEGER PRIMARY KEY CHECK (singleton = 1),
    log_id         TEXT NOT NULL,
    format_version INTEGER NOT NULL CHECK (format_version = 1),
    created_at     TEXT NOT NULL
  ) STRICT;

  CREATE TABLE IF NOT EXISTS entries (
    arrival_seq    INTEGER PRIMARY KEY AUTOINCREMENT,
    entry_id       TEXT NOT NULL UNIQUE,
    writer_id      TEXT NOT NULL,
    writer_seq     INTEGER NOT NULL CHECK (writer_seq > 0),
    prev_entry_id  TEXT,
    created_at     TEXT NOT NULL,
    canonical_json BLOB NOT NULL CHECK (length(canonical_json) <= 1048576),
    received_at_ms INTEGER NOT NULL,
    UNIQUE (writer_id, writer_seq)
  ) STRICT;

  CREATE INDEX IF NOT EXISTS entries_by_writer
    ON entries (writer_id, writer_seq);

  CREATE TABLE IF NOT EXISTS writer_tips (
    writer_id    TEXT PRIMARY KEY,
    last_seq     INTEGER NOT NULL CHECK (last_seq > 0),
    last_entry_id TEXT NOT NULL
  ) STRICT;
  """

  @triggers """
  CREATE TRIGGER IF NOT EXISTS entries_no_update
    BEFORE UPDATE ON entries
  BEGIN
    SELECT RAISE(ABORT, 'entries are immutable');
  END;

  CREATE TRIGGER IF NOT EXISTS entries_no_delete
    BEFORE DELETE ON entries
  BEGIN
    SELECT RAISE(ABORT, 'entries are immutable');
  END;
  """

  @doc "The verbatim §12 DDL — three STRICT tables and one index."
  @spec ddl() :: String.t()
  def ddl, do: @ddl

  @doc "The immutability triggers (pure addition; not part of the pinned DDL)."
  @spec triggers() :: String.t()
  def triggers, do: @triggers

  @doc """
  Create the §12 schema plus the immutability triggers on `conn`. Every
  statement is IF NOT EXISTS, so re-running is a no-op (idempotent).

  `Exqlite.Sqlite3.execute/2` runs multi-statement scripts ("Multiple
  stanzas can be passed at once"), so each constant executes in one call.
  """
  @spec init_schema(Sqlite3.db()) :: :ok | {:error, term()}
  def init_schema(conn) do
    with :ok <- Sqlite3.execute(conn, @ddl) do
      Sqlite3.execute(conn, @triggers)
    end
  end
end
