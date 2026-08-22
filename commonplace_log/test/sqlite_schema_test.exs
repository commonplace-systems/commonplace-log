defmodule Commonplace.LogStore.SQLite.SchemaTest do
  use ExUnit.Case, async: true

  alias Commonplace.LogStore.SQLite.Schema
  alias Exqlite.Sqlite3

  @moduledoc """
  SP3 Task 1: §12 schema + immutability triggers over exqlite, the Elixir
  twin of `worker/test/do/schema.test.ts`.

  The DDL is pinned verbatim in the spec; `Schema.ddl/0` must be a
  byte-for-byte copy (the fidelity gate below makes transcription drift
  detectable). The triggers are an ADDITION executed after the DDL and must
  never require altering any pinned column, constraint, or index.
  """

  @spec_path Path.expand("../../docs/commonplace-monotonic-log-spec.md", __DIR__)
  @writer_id "fab4e8a5-ce9e-48d0-8f78-1d312b978207"

  # --- helpers -------------------------------------------------------------

  defp spec_text do
    assert File.exists?(@spec_path), "spec file missing at #{@spec_path}"
    text = File.read!(@spec_path)
    assert byte_size(text) > 0, "spec file is empty — extraction corpus would be vacuous"
    text
  end

  # Strip trailing whitespace per line — the ONLY normalization permitted.
  defp norm(s) do
    s
    |> String.split("\n")
    |> Enum.map(&String.replace(&1, ~r/[ \t]+$/, ""))
    |> Enum.join("\n")
  end

  # The whole §12 ```sql block body (between the fences, exclusive).
  defp extract_section12_block(spec) do
    {heading, _} = :binary.match(spec, "## 12. SQLite storage layout")
    after_heading = binary_part(spec, heading, byte_size(spec) - heading)
    {fence_open_rel, fence_open_len} = :binary.match(after_heading, "```sql\n")
    body_start = heading + fence_open_rel + fence_open_len
    after_open = binary_part(spec, body_start, byte_size(spec) - body_start)
    {fence_close_rel, _} = :binary.match(after_open, "```")
    assert fence_close_rel > 0, "§12 sql fence closed immediately — empty block"
    binary_part(spec, body_start, fence_close_rel)
  end

  # The individual SQL statements of the block. No statement in the pinned
  # DDL contains an interior semicolon, so splitting on ";" is exact.
  defp extract_section12_statements(spec) do
    spec
    |> extract_section12_block()
    |> String.split(";")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&(&1 <> ";"))
  end

  defp open_initialized do
    {:ok, conn} = Sqlite3.open(":memory:")
    :ok = Schema.init_schema(conn)
    conn
  end

  # name -> %{type, sql} for everything in sqlite_master.
  defp schema_objects(conn) do
    query(conn, "SELECT name, type, sql FROM sqlite_master")
    |> Map.new(fn [name, type, sql] -> {name, %{type: type, sql: sql}} end)
  end

  defp query(conn, sql, params \\ []) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, params)
    rows = fetch_all(conn, stmt)
    :ok = Sqlite3.release(conn, stmt)
    rows
  end

  defp fetch_all(conn, stmt) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> [row | fetch_all(conn, stmt)]
      :done -> []
    end
  end

  # A parameterized statement expected to FAIL: returns the {:error, reason}
  # from whichever phase (prepare/bind/step) rejects it.
  defp run(conn, sql, params) do
    with {:ok, stmt} <- Sqlite3.prepare(conn, sql),
         :ok <- Sqlite3.bind(stmt, params),
         :done <- Sqlite3.step(conn, stmt) do
      :ok = Sqlite3.release(conn, stmt)
      :ok
    end
  end

  # Insert a minimal STRICT-satisfying row into `entries` (direct SQL is fine
  # at this layer).
  defp insert_entry(conn, entry_id, writer_seq) do
    :ok =
      run(
        conn,
        """
        INSERT INTO entries
          (entry_id, writer_id, writer_seq, prev_entry_id, created_at, canonical_json, received_at_ms)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        [
          entry_id,
          @writer_id,
          writer_seq,
          if(writer_seq == 1, do: nil, else: "entry-#{writer_seq - 1}"),
          "2026-08-22T00:00:00Z",
          {:blob, ~s({"n":#{writer_seq}})},
          1_766_000_000_000
        ]
      )
  end

  # --- §12 DDL fidelity gate (copy, don't retype) --------------------------

  describe "§12 schema DDL fidelity gate" do
    test "ddl/0 contains each of the four §12 statements exactly" do
      statements = extract_section12_statements(spec_text())

      # Anti-vacuity floor: an empty or partial extraction must fail loudly
      # before any containment check can vacuously pass.
      assert length(statements) == 4

      expected_objects = ["log_meta", "entries", "entries_by_writer", "writer_tips"]

      for {name, i} <- Enum.with_index(expected_objects) do
        assert Enum.at(statements, i) =~ name,
               "statement #{i} does not mention #{name}"
      end

      for statement <- statements do
        assert String.contains?(norm(Schema.ddl()), norm(statement)),
               "ddl/0 missing statement:\n#{statement}"
      end
    end

    test "ddl/0 equals the whole §12 block — no fifth statement can hide" do
      block = extract_section12_block(spec_text())
      # Whole-block equality: containment alone would let ddl/0 grow
      # statements the spec does not pin.
      assert String.trim(norm(Schema.ddl())) == String.trim(norm(block))
    end

    test "control: a deliberately perturbed statement does NOT match (the gate can fire)" do
      statements = extract_section12_statements(spec_text())
      assert length(statements) == 4
      entries_table = Enum.at(statements, 1)

      perturbed =
        String.replace(
          entries_table,
          "canonical_json BLOB NOT NULL",
          "canonical_json TEXT NOT NULL"
        )

      # Prove the perturbation actually changed the statement…
      refute perturbed == entries_table
      # …and that the gate rejects it: containment is not vacuous.
      refute String.contains?(norm(Schema.ddl()), norm(perturbed))
    end

    test "triggers/0 is a separate ADDITION: both triggers, IF NOT EXISTS, RAISE text" do
      triggers = Schema.triggers()
      assert triggers =~ "CREATE TRIGGER IF NOT EXISTS entries_no_update"
      assert triggers =~ "CREATE TRIGGER IF NOT EXISTS entries_no_delete"
      assert triggers =~ "RAISE(ABORT, 'entries are immutable')"
      # Pure addition: the pinned DDL string itself carries no trigger.
      refute Schema.ddl() =~ "TRIGGER"
    end
  end

  # --- init_schema ---------------------------------------------------------

  describe "init_schema/1" do
    test "creates the three STRICT tables and the entries_by_writer index" do
      conn = open_initialized()
      objects = schema_objects(conn)

      for table <- ["log_meta", "entries", "writer_tips"] do
        assert %{type: "table", sql: sql} = objects[table],
               "table #{table} missing from sqlite_master"

        assert sql =~ "STRICT", "table #{table} must be STRICT"
      end

      assert %{type: "index", sql: index_sql} = objects["entries_by_writer"],
             "index entries_by_writer missing from sqlite_master"

      assert index_sql =~ "ON entries (writer_id, writer_seq)"
    end

    test "is idempotent: re-running init_schema is a no-op and preserves existing data" do
      conn = open_initialized()
      insert_entry(conn, "entry-1", 1)

      assert :ok = Schema.init_schema(conn)

      objects = schema_objects(conn)

      for name <- ["log_meta", "entries", "writer_tips", "entries_by_writer"] do
        assert Map.has_key?(objects, name), "#{name} missing after re-init"
      end

      assert [[1]] = query(conn, "SELECT COUNT(*) FROM entries")
    end

    test "installs both immutability triggers" do
      conn = open_initialized()
      objects = schema_objects(conn)

      for trigger <- ["entries_no_update", "entries_no_delete"] do
        assert %{type: "trigger", sql: sql} = objects[trigger],
               "trigger #{trigger} missing from sqlite_master"

        assert sql =~ "entries are immutable"
      end
    end
  end

  # --- immutability trigger red paths (the recorded artifact) --------------

  describe "immutability trigger red paths" do
    test "UPDATE on a committed entry fails: error text contains 'entries are immutable'" do
      conn = open_initialized()
      insert_entry(conn, "entry-1", 1)

      result =
        Sqlite3.execute(conn, "UPDATE entries SET created_at = 'x' WHERE entry_id = 'entry-1'")

      # Full observed error text (exqlite 0.39.0 / Elixir 1.18.4, recorded
      # 2026-08-22): {:error, "entries are immutable"} — exqlite surfaces
      # sqlite3_errmsg() alone, without workerd's ": SQLITE_CONSTRAINT" suffix
      # (worker/test/do/schema.test.ts records "entries are immutable:
      # SQLITE_CONSTRAINT" for the same trigger).
      assert {:error, reason} = result
      assert reason =~ "entries are immutable", "unexpected error text: #{inspect(result)}"

      # Verify by effect: the row is untouched.
      assert [["2026-08-22T00:00:00Z"]] =
               query(conn, "SELECT created_at FROM entries WHERE entry_id = 'entry-1'")
    end

    test "DELETE on a committed entry fails: error text contains 'entries are immutable'" do
      conn = open_initialized()
      insert_entry(conn, "entry-1", 1)

      result = Sqlite3.execute(conn, "DELETE FROM entries WHERE entry_id = 'entry-1'")

      # Full observed error text (exqlite 0.39.0 / Elixir 1.18.4, recorded
      # 2026-08-22): {:error, "entries are immutable"} — same rendering as the
      # UPDATE path.
      assert {:error, reason} = result
      assert reason =~ "entries are immutable", "unexpected error text: #{inspect(result)}"

      # Verify by effect: the row survived.
      assert [[1]] = query(conn, "SELECT COUNT(*) FROM entries")
    end

    test "INSERT into entries still works after the triggers exist" do
      conn = open_initialized()
      insert_entry(conn, "entry-1", 1)
      insert_entry(conn, "entry-2", 2)
      assert [[2]] = query(conn, "SELECT COUNT(*) FROM entries")
    end

    test "does not overreach: UPDATE and DELETE on writer_tips still work" do
      conn = open_initialized()

      :ok =
        run(
          conn,
          "INSERT INTO writer_tips (writer_id, last_seq, last_entry_id) VALUES (?, ?, ?)",
          [@writer_id, 1, "entry-1"]
        )

      :ok =
        run(
          conn,
          "UPDATE writer_tips SET last_seq = 2, last_entry_id = 'entry-2' WHERE writer_id = ?",
          [@writer_id]
        )

      assert [[2, "entry-2"]] = query(conn, "SELECT last_seq, last_entry_id FROM writer_tips")

      :ok = run(conn, "DELETE FROM writer_tips WHERE writer_id = ?", [@writer_id])
      assert [[0]] = query(conn, "SELECT COUNT(*) FROM writer_tips")
    end
  end
end
