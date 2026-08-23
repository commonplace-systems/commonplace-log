defmodule Commonplace.Log.Persistence.LocalSQLite do
  @moduledoc """
  SQLite persistence with one database file per log.

  Open handles are `%#{__MODULE__}{conn: conn, data_dir: data_dir, log_id: log_id,
  path: path}`. `conn` is the live `Exqlite.Sqlite3` connection, `data_dir` is
  the directory supplied to `open/2`, `log_id` binds the handle to its file,
  and `path` is `<data_dir>/<log_id>.sqlite3`.

  """

  @behaviour Commonplace.Log.Persistence

  alias Commonplace.Log.Persistence.{CommitPlan, ReadSet}
  alias Commonplace.LogStore.SQLite.Schema
  alias Exqlite.Sqlite3

  @meta_ddl """
  CREATE TABLE IF NOT EXISTS persistence_meta (
    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
    revision  INTEGER NOT NULL,
    lease_epoch INTEGER NOT NULL DEFAULT 0
  ) STRICT;
  """

  @enforce_keys [:conn, :data_dir, :log_id, :path]
  defstruct [:conn, :data_dir, :log_id, :path]

  @type t :: %__MODULE__{
          conn: Sqlite3.db(),
          data_dir: String.t(),
          log_id: String.t(),
          path: String.t()
        }

  @doc "Open the SQLite file assigned to `log_id` and apply durability pragmas."
  @spec open(Path.t(), String.t()) :: {:ok, t()} | {:error, term()}
  def open(data_dir, log_id) when is_binary(data_dir) and is_binary(log_id) do
    with :ok <- File.mkdir_p(data_dir),
         path = Path.join(data_dir, log_id <> ".sqlite3"),
         {:ok, conn} <- Sqlite3.open(path),
         :ok <- configure(conn) do
      {:ok, %__MODULE__{conn: conn, data_dir: data_dir, log_id: log_id, path: path}}
    else
      {:error, _reason} = error -> error
    end
  end

  @doc "Close an open store handle."
  @spec close(t()) :: :ok | {:error, term()}
  def close(%__MODULE__{conn: conn}), do: Sqlite3.close(conn)

  @impl true
  def create_log(%__MODULE__{} = store, log_id, metadata) do
    with :ok <- handle_matches(store, log_id),
         :ok <- Schema.init_schema(store.conn),
         :ok <- Sqlite3.execute(store.conn, @meta_ddl),
         :ok <- ensure_lease_epoch_column(store.conn) do
      transaction(store.conn, "BEGIN IMMEDIATE", fn ->
        create_or_check_log(store.conn, log_id, format_version(metadata))
      end)
    end
  end

  @impl true
  def take_lease(%__MODULE__{} = store, log_id) do
    transaction(store.conn, "BEGIN IMMEDIATE", fn ->
      with :ok <- stored_log_matches(store, log_id),
           {:ok, epoch} <- lease_epoch(store.conn),
           {:ok, [[new_epoch]]} <-
             query(
               store.conn,
               "UPDATE persistence_meta SET lease_epoch = lease_epoch + 1 " <>
                 "WHERE singleton = 1 AND lease_epoch = ? RETURNING lease_epoch",
               [epoch]
             ) do
        {:ok, new_epoch}
      else
        {:ok, []} -> {:error, :stale_epoch}
        {:error, _reason} = error -> error
      end
    end)
  end

  @impl true
  def read_set(%__MODULE__{} = store, log_id, query_spec) do
    transaction(store.conn, "BEGIN", fn ->
      with :ok <- stored_log_matches(store, log_id),
           {:ok, revision} <- revision(store.conn),
           {:ok, lease_epoch} <- lease_epoch(store.conn),
           {:ok, tips} <- read_tips(store.conn, Map.get(query_spec, :writers, [])),
           {:ok, coordinates} <-
             read_coordinates(store.conn, Map.get(query_spec, :coordinates, [])),
           {:ok, entry_ids} <- read_entry_ids(store.conn, Map.get(query_spec, :entry_ids, [])) do
        {:ok,
         %ReadSet{
           log_id: log_id,
           revision: revision,
           lease_epoch: lease_epoch,
           tips: tips,
           coordinates: coordinates,
           entry_ids: entry_ids
         }}
      end
    end)
  end

  @impl true
  def commit(%__MODULE__{} = store, %CommitPlan{} = plan) do
    transaction(store.conn, "BEGIN IMMEDIATE", fn ->
      with :ok <- stored_log_matches(store, plan.log_id),
           {:ok, revision} <- revision(store.conn),
           :ok <- check_revision(revision, plan.expected_revision),
           {:ok, lease_epoch} <- lease_epoch(store.conn),
           :ok <- check_epoch(lease_epoch, plan.expected_epoch),
           :ok <- insert_entries(store.conn, plan.insert_entries),
           :ok <- put_tips(store.conn, plan.put_tips),
           :ok <- advance_revision(store.conn, plan.expected_revision) do
        {:ok, plan.expected_revision + 1}
      end
    end)
  end

  @impl true
  def frontier(%__MODULE__{} = store, log_id) do
    with :ok <- stored_log_matches(store, log_id),
         {:ok, rows} <-
           query(
             store.conn,
             "SELECT writer_id, last_seq, last_entry_id FROM writer_tips ORDER BY writer_id"
           ) do
      {:ok,
       %{
         writers:
           Enum.map(rows, fn [writer_id, seq, entry_id] ->
             %{writer_id: writer_id, seq: seq, entry_id: entry_id}
           end)
       }}
    end
  end

  @impl true
  def read_writer(%__MODULE__{} = store, log_id, writer_id, opts) do
    after_seq = Keyword.fetch!(opts, :after_seq)
    through_seq = Keyword.get(opts, :through_seq)
    limit = Keyword.fetch!(opts, :limit)

    {through_clause, params} =
      if is_nil(through_seq) do
        {"", [writer_id, after_seq, limit + 1]}
      else
        {" AND writer_seq <= ?", [writer_id, after_seq, through_seq, limit + 1]}
      end

    with :ok <- stored_log_matches(store, log_id),
         {:ok, rows} <-
           query(
             store.conn,
             "SELECT canonical_json, writer_seq FROM entries " <>
               "WHERE writer_id = ? AND writer_seq > ?" <>
               through_clause <> " ORDER BY writer_seq LIMIT ?",
             params
           ) do
      {page, more} = split_page(rows, limit)

      entries =
        Enum.map(page, fn [canonical_bytes, writer_seq] ->
          %{canonical_bytes: canonical_bytes, writer_seq: writer_seq}
        end)

      {:ok,
       %{
         entries: entries,
         next_after_seq: if(more, do: page |> List.last() |> Enum.at(1), else: nil)
       }}
    end
  end

  @impl true
  def tail_local(%__MODULE__{} = store, log_id, opts) do
    after_arrival = Keyword.fetch!(opts, :after_arrival)
    limit = Keyword.fetch!(opts, :limit)

    with :ok <- stored_log_matches(store, log_id),
         {:ok, rows} <-
           query(
             store.conn,
             "SELECT canonical_json, arrival_seq FROM entries " <>
               "WHERE arrival_seq > ? ORDER BY arrival_seq LIMIT ?",
             [after_arrival, limit + 1]
           ) do
      {page, more} = split_page(rows, limit)

      entries =
        Enum.map(page, fn [canonical_bytes, arrival_seq] ->
          %{canonical_bytes: canonical_bytes, arrival_seq: arrival_seq}
        end)

      {:ok,
       %{
         entries: entries,
         next_after_arrival: if(more, do: page |> List.last() |> Enum.at(1), else: nil)
       }}
    end
  end

  defp configure(conn) do
    with :ok <- Sqlite3.execute(conn, "PRAGMA journal_mode = WAL"),
         :ok <- Sqlite3.execute(conn, "PRAGMA synchronous = FULL") do
      :ok
    else
      {:error, _reason} = error ->
        Sqlite3.close(conn)
        error
    end
  end

  defp create_or_check_log(conn, log_id, format_version) do
    with {:ok, rows} <- query(conn, "SELECT log_id FROM log_meta WHERE singleton = 1") do
      case rows do
        [] ->
          with :ok <-
                 run(
                   conn,
                   "INSERT INTO log_meta (singleton, log_id, format_version, created_at) VALUES (1, ?, ?, ?)",
                   [log_id, format_version, DateTime.utc_now() |> DateTime.to_iso8601()]
                 ) do
            run(
              conn,
              "INSERT INTO persistence_meta (singleton, revision, lease_epoch) VALUES (1, 0, 0) " <>
                "ON CONFLICT(singleton) DO NOTHING"
            )
          end

        [[^log_id]] ->
          run(
            conn,
            "INSERT INTO persistence_meta (singleton, revision, lease_epoch) VALUES (1, 0, 0) " <>
              "ON CONFLICT(singleton) DO NOTHING"
          )

        [[_other]] ->
          {:error, :log_mismatch}
      end
    end
  end

  defp format_version(metadata),
    do: Map.get(metadata, :format_version, Map.get(metadata, "format_version", 1))

  defp handle_matches(%__MODULE__{log_id: log_id}, log_id), do: :ok
  defp handle_matches(_store, _log_id), do: {:error, :log_mismatch}

  defp stored_log_matches(store, log_id) do
    with :ok <- handle_matches(store, log_id),
         {:ok, rows} <- query(store.conn, "SELECT log_id FROM log_meta WHERE singleton = 1") do
      case rows do
        [[^log_id]] -> :ok
        [[_other]] -> {:error, :log_mismatch}
        [] -> {:error, :not_found}
      end
    else
      {:error, "no such table: log_meta"} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp revision(conn) do
    case query(conn, "SELECT revision FROM persistence_meta WHERE singleton = 1") do
      {:ok, [[revision]]} -> {:ok, revision}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp lease_epoch(conn) do
    case query(conn, "SELECT lease_epoch FROM persistence_meta WHERE singleton = 1") do
      {:ok, [[epoch]]} -> {:ok, epoch}
      {:ok, []} -> {:error, :not_found}
      {:error, _reason} = error -> error
    end
  end

  defp ensure_lease_epoch_column(conn) do
    with {:ok, rows} <- query(conn, "PRAGMA table_info(persistence_meta)") do
      if Enum.any?(rows, fn row -> Enum.at(row, 1) == "lease_epoch" end) do
        :ok
      else
        Sqlite3.execute(
          conn,
          "ALTER TABLE persistence_meta ADD COLUMN lease_epoch INTEGER NOT NULL DEFAULT 0"
        )
      end
    end
  end

  defp read_tips(_conn, []), do: {:ok, %{}}

  defp read_tips(conn, writers) do
    sql =
      "SELECT writer_id, last_seq, last_entry_id FROM writer_tips WHERE writer_id IN (" <>
        placeholders(writers) <> ")"

    with {:ok, rows} <- query(conn, sql, writers) do
      {:ok,
       Map.new(rows, fn [writer_id, seq, entry_id] ->
         {writer_id, %{seq: seq, entry_id: entry_id}}
       end)}
    end
  end

  defp read_coordinates(_conn, []), do: {:ok, %{}}

  defp read_coordinates(conn, coordinates) do
    clauses = Enum.map_join(coordinates, " OR ", fn _ -> "(writer_id = ? AND writer_seq = ?)" end)
    params = Enum.flat_map(coordinates, fn {writer_id, seq} -> [writer_id, seq] end)

    with {:ok, rows} <-
           query(
             conn,
             "SELECT writer_id, writer_seq, canonical_json FROM entries WHERE " <> clauses,
             params
           ) do
      {:ok,
       Map.new(rows, fn [writer_id, writer_seq, canonical_bytes] ->
         {{writer_id, writer_seq}, canonical_bytes}
       end)}
    end
  end

  defp read_entry_ids(_conn, []), do: {:ok, %{}}

  defp read_entry_ids(conn, entry_ids) do
    sql =
      "SELECT entry_id, canonical_json FROM entries WHERE entry_id IN (" <>
        placeholders(entry_ids) <> ")"

    with {:ok, rows} <- query(conn, sql, entry_ids) do
      {:ok, Map.new(rows, fn [entry_id, canonical_bytes] -> {entry_id, canonical_bytes} end)}
    end
  end

  defp insert_entries(conn, rows) do
    now = System.system_time(:millisecond)

    Enum.reduce_while(rows, :ok, fn row, :ok ->
      result =
        run(
          conn,
          "INSERT INTO entries " <>
            "(entry_id, writer_id, writer_seq, prev_entry_id, created_at, canonical_json, received_at_ms) " <>
            "VALUES (?, ?, ?, ?, ?, ?, ?)",
          [
            row.entry_id,
            row.writer_id,
            row.writer_seq,
            row.prev_entry_id,
            row.created_at,
            {:blob, row.canonical_bytes},
            now
          ]
        )

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp put_tips(conn, tips) do
    Enum.reduce_while(tips, :ok, fn tip, :ok ->
      result =
        run(
          conn,
          "INSERT INTO writer_tips (writer_id, last_seq, last_entry_id) VALUES (?, ?, ?) " <>
            "ON CONFLICT(writer_id) DO UPDATE SET " <>
            "last_seq = excluded.last_seq, last_entry_id = excluded.last_entry_id",
          [tip.writer_id, tip.seq, tip.entry_id]
        )

      case result do
        :ok -> {:cont, :ok}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp advance_revision(conn, expected_revision) do
    run(
      conn,
      "UPDATE persistence_meta SET revision = revision + 1 " <>
        "WHERE singleton = 1 AND revision = ?",
      [expected_revision]
    )
  end

  defp check_revision(revision, revision), do: :ok
  defp check_revision(_revision, _expected), do: {:error, :stale_revision}

  defp check_epoch(epoch, epoch), do: :ok
  defp check_epoch(_epoch, _expected), do: {:error, :obsolete_epoch}

  defp split_page(rows, limit) do
    if length(rows) > limit, do: {Enum.take(rows, limit), true}, else: {rows, false}
  end

  defp placeholders(items), do: Enum.map_join(items, ",", fn _ -> "?" end)

  defp transaction(conn, begin_sql, fun) do
    with :ok <- Sqlite3.execute(conn, begin_sql) do
      case fun.() do
        {:ok, value} ->
          case Sqlite3.execute(conn, "COMMIT") do
            :ok -> {:ok, value}
            {:error, _reason} = error -> rollback(conn, error)
          end

        :ok ->
          case Sqlite3.execute(conn, "COMMIT") do
            :ok -> :ok
            {:error, _reason} = error -> rollback(conn, error)
          end

        {:error, _reason} = error ->
          rollback(conn, error)
      end
    end
  end

  defp rollback(conn, error) do
    _ = Sqlite3.execute(conn, "ROLLBACK")
    error
  end

  defp query(conn, sql, params \\ []) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        result =
          with :ok <- Sqlite3.bind(stmt, params) do
            fetch_all(conn, stmt, [])
          end

        _ = Sqlite3.release(conn, stmt)
        result

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_all(conn, stmt, rows) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all(conn, stmt, [row | rows])
      :done -> {:ok, Enum.reverse(rows)}
      {:error, _reason} = error -> error
    end
  end

  defp run(conn, sql, params \\ []) do
    case Sqlite3.prepare(conn, sql) do
      {:ok, stmt} ->
        result =
          with :ok <- Sqlite3.bind(stmt, params) do
            case Sqlite3.step(conn, stmt) do
              :done -> :ok
              {:error, _reason} = error -> error
            end
          end

        _ = Sqlite3.release(conn, stmt)
        result

      {:error, _reason} = error ->
        error
    end
  end
end
