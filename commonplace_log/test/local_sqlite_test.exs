defmodule Commonplace.Log.Persistence.LocalSQLiteTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.Persistence.{CommitPlan, LocalSQLite, ReadSet}
  alias Commonplace.Log.Test.InMemoryPersistence
  alias Exqlite.Sqlite3

  @log_id "018f0000-0000-7000-8000-000000000001"

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "commonplace-local-sqlite-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)
    %{data_dir: data_dir}
  end

  test "create_log is idempotent and rejects a mismatched log on a live handle and re-open", %{
    data_dir: data_dir
  } do
    store = open_store(data_dir)
    assert :ok = LocalSQLite.create_log(store, @log_id, %{format_version: 1})
    assert :ok = LocalSQLite.create_log(store, @log_id, %{format_version: 1})

    assert {:error, :log_mismatch} =
             LocalSQLite.create_log(store, "other-log", %{format_version: 1})

    assert :ok = LocalSQLite.close(store)

    # Put an existing database under a different requested file name. A fresh
    # handle must trust the stored identity, not merely the path it opened.
    File.cp!(
      Path.join(data_dir, @log_id <> ".sqlite3"),
      Path.join(data_dir, "other-log.sqlite3")
    )

    assert {:ok, mismatched_file} = LocalSQLite.open(data_dir, "other-log")

    assert {:error, :log_mismatch} =
             LocalSQLite.create_log(mismatched_file, "other-log", %{format_version: 1})

    assert :ok = LocalSQLite.close(mismatched_file)

    reopened = open_store(data_dir)

    assert {:error, :log_mismatch} =
             LocalSQLite.create_log(reopened, "other-log", %{format_version: 1})

    assert :ok = LocalSQLite.create_log(reopened, @log_id, %{format_version: 1})
    assert :ok = LocalSQLite.close(reopened)
  end

  test "open applies WAL and FULL durability pragmas", %{data_dir: data_dir} do
    store = initialized_store(data_dir)
    assert [["wal"]] = query(store.conn, "PRAGMA journal_mode")
    assert [[2]] = query(store.conn, "PRAGMA synchronous")
    close_store(store)
  end

  test "an existing revision-only persistence_meta is upgraded additively", %{data_dir: data_dir} do
    store = open_store(data_dir)

    assert :ok =
             Sqlite3.execute(store.conn, """
             CREATE TABLE persistence_meta (
               singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
               revision INTEGER NOT NULL
             ) STRICT
             """)

    assert :ok = LocalSQLite.create_log(store, @log_id, %{format_version: 1})
    assert [[0, 0]] = query(store.conn, "SELECT revision, lease_epoch FROM persistence_meta")
    assert {:ok, 1} = LocalSQLite.take_lease(store, @log_id)
    close_store(store)
  end

  test "every read reports not_found when an opened log has no schema", %{data_dir: data_dir} do
    store = open_store(data_dir)
    query = %{writers: [], coordinates: [], entry_ids: []}

    assert {:error, :not_found} = LocalSQLite.read_set(store, @log_id, query)
    assert {:error, :not_found} = LocalSQLite.frontier(store, @log_id)

    assert {:error, :not_found} =
             LocalSQLite.read_writer(store, @log_id, "writer-a", after_seq: 0, limit: 1)

    assert {:error, :not_found} =
             LocalSQLite.tail_local(store, @log_id, after_arrival: 0, limit: 1)

    close_store(store)
  end

  test "a malformed log schema remains distinguishable from a missing log", %{data_dir: data_dir} do
    store = open_store(data_dir)
    assert :ok = Sqlite3.execute(store.conn, "CREATE TABLE log_meta (wrong_column TEXT)")

    assert {:error, reason} =
             LocalSQLite.read_set(store, @log_id, %{
               writers: [],
               coordinates: [],
               entry_ids: []
             })

    assert reason == "no such column: log_id"
    refute reason == :not_found
    close_store(store)
  end

  test "a physically corrupt database fails distinguishably during open", %{data_dir: data_dir} do
    File.write!(Path.join(data_dir, @log_id <> ".sqlite3"), "not a sqlite database")

    assert {:error, reason} = LocalSQLite.open(data_dir, @log_id)
    assert is_binary(reason)
    assert String.contains?(reason, "file is not a database")
    refute reason == :not_found
  end

  test "read_set returns one revision with exactly the requested tips, coordinates, and ids", %{
    data_dir: data_dir
  } do
    store = initialized_store(data_dir)
    rows = [row("writer-b", 1, "entry-b1", <<0, 1, 2>>), row("writer-a", 1, "entry-a1", "a1")]
    assert {:ok, 1} = LocalSQLite.commit(store, plan(0, rows))

    assert {:ok,
            %ReadSet{
              log_id: @log_id,
              revision: 1,
              tips: %{"writer-a" => %{seq: 1, entry_id: "entry-a1"}},
              coordinates: %{{"writer-b", 1} => <<0, 1, 2>>},
              entry_ids: %{"entry-a1" => "a1"}
            }} =
             LocalSQLite.read_set(store, @log_id, %{
               writers: ["writer-a", "missing"],
               coordinates: [{"writer-b", 1}, {"writer-b", 99}],
               entry_ids: ["entry-a1", "missing"]
             })

    assert {:ok, %ReadSet{tips: %{}, coordinates: %{}, entry_ids: %{}}} =
             LocalSQLite.read_set(store, @log_id, %{writers: [], coordinates: [], entry_ids: []})

    close_store(store)
  end

  test "commit stores the plan BLOB byte-for-byte and advances revision exactly once", %{
    data_dir: data_dir
  } do
    store = initialized_store(data_dir)
    bytes = <<0, 255, 10, 13, 123, 125>>
    assert {:ok, 1} = LocalSQLite.commit(store, plan(0, [row("writer-a", 1, "entry-a1", bytes)]))

    assert [[stored]] =
             query(store.conn, "SELECT canonical_json FROM entries WHERE entry_id = ?", [
               "entry-a1"
             ])

    assert stored == bytes
    assert [[1]] = query(store.conn, "SELECT revision FROM persistence_meta")
    close_store(store)
  end

  test "entry projection columns agree with each row's canonical bytes", %{data_dir: data_dir} do
    store = initialized_store(data_dir)

    {rows, _last_id} =
      Enum.map_reduce(1..3, nil, fn seq, prev_entry_id ->
        entry_id = "entry-a#{seq}"
        created_at = "2026-08-22T12:34:5#{seq}Z"

        canonical_bytes =
          Jason.encode!(%{
            "entry_id" => entry_id,
            "writer_id" => "writer-a",
            "writer_seq" => seq,
            "prev_entry_id" => prev_entry_id,
            "created_at" => created_at
          })

        projected_row =
          row("writer-a", seq, entry_id, canonical_bytes)
          |> Map.put(:prev_entry_id, prev_entry_id)
          |> Map.put(:created_at, created_at)

        {projected_row, entry_id}
      end)

    assert {:ok, 1} = LocalSQLite.commit(store, plan(0, rows))

    stored_rows =
      query(
        store.conn,
        "SELECT entry_id, writer_id, writer_seq, prev_entry_id, created_at, canonical_json " <>
          "FROM entries ORDER BY writer_seq"
      )

    Enum.each(stored_rows, fn [entry_id, writer_id, writer_seq, prev_entry_id, created_at, bytes] ->
      parsed = Jason.decode!(bytes)

      assert [entry_id, writer_id, writer_seq, prev_entry_id, created_at] ==
               Enum.map(
                 ["entry_id", "writer_id", "writer_seq", "prev_entry_id", "created_at"],
                 &Map.fetch!(parsed, &1)
               )
    end)

    close_store(store)
  end

  test "a stale revision returns stale_revision and stores nothing", %{data_dir: data_dir} do
    store = initialized_store(data_dir)
    assert {:ok, %ReadSet{revision: 0}} = empty_read(store)

    assert :ok =
             Sqlite3.execute(store.conn, "UPDATE persistence_meta SET revision = revision + 1")

    assert {:error, :stale_revision} =
             LocalSQLite.commit(store, plan(0, [row("writer-a", 1, "entry-a1", "bytes")]))

    assert [[0]] = query(store.conn, "SELECT COUNT(*) FROM entries")
    assert [[0]] = query(store.conn, "SELECT COUNT(*) FROM writer_tips")
    assert [[1]] = query(store.conn, "SELECT revision FROM persistence_meta")
    close_store(store)
  end

  test "leases advance monotonically and the current epoch permits ordinary commits", %{
    data_dir: data_dir
  } do
    store = initialized_store(data_dir)

    assert {:ok, 1} = LocalSQLite.take_lease(store, @log_id)
    assert {:ok, 2} = LocalSQLite.take_lease(store, @log_id)
    assert {:ok, %ReadSet{lease_epoch: 2}} = empty_read(store)

    assert {:ok, 1} =
             LocalSQLite.commit(
               store,
               plan(0, [row("writer-a", 1, "entry-a1", "bytes")], 2)
             )

    assert [[1, 2]] = query(store.conn, "SELECT revision, lease_epoch FROM persistence_meta")
    close_store(store)
  end

  test "obsolete epoch and stale revision are distinct and neither writes", %{data_dir: data_dir} do
    store = initialized_store(data_dir)
    assert {:ok, 1} = LocalSQLite.take_lease(store, @log_id)
    candidate = row("writer-a", 1, "entry-a1", "bytes")

    assert {:error, :obsolete_epoch} = LocalSQLite.commit(store, plan(0, [candidate], 0))
    assert [[0]] = query(store.conn, "SELECT COUNT(*) FROM entries")

    assert {:error, :stale_revision} = LocalSQLite.commit(store, plan(99, [candidate], 1))
    assert [[0]] = query(store.conn, "SELECT COUNT(*) FROM entries")
    close_store(store)
  end

  test "a later invalid row rolls back the entire multi-row commit", %{data_dir: data_dir} do
    store = initialized_store(data_dir)
    good = row("writer-a", 1, "entry-a1", "first-would-have-succeeded")
    invalid = row("writer-b", 0, "entry-b0", "invalid-writer-seq")

    assert {:error, "CHECK constraint failed: writer_seq > 0"} =
             LocalSQLite.commit(store, plan(0, [good, invalid]))

    assert [[0]] = query(store.conn, "SELECT COUNT(*) FROM entries")
    assert [[0]] = query(store.conn, "SELECT COUNT(*) FROM writer_tips")
    assert [[0]] = query(store.conn, "SELECT revision FROM persistence_meta")
    close_store(store)
  end

  test "schema additions preserve entry UPDATE and DELETE immutability", %{data_dir: data_dir} do
    store = initialized_store(data_dir)

    assert {:ok, 1} =
             LocalSQLite.commit(store, plan(0, [row("writer-a", 1, "entry-a1", "bytes")]))

    assert {:error, "entries are immutable"} =
             Sqlite3.execute(store.conn, "UPDATE entries SET created_at = 'x'")

    assert {:error, "entries are immutable"} = Sqlite3.execute(store.conn, "DELETE FROM entries")
    assert [[1]] = query(store.conn, "SELECT COUNT(*) FROM entries")
    close_store(store)
  end

  test "frontier returns at least three writers sorted by writer_id", %{data_dir: data_dir} do
    store = initialized_store(data_dir)

    rows = [
      row("writer-c", 1, "c1", "c"),
      row("writer-a", 1, "a1", "a"),
      row("writer-b", 1, "b1", "b")
    ]

    assert {:ok, 1} = LocalSQLite.commit(store, plan(0, rows))

    assert {:ok,
            %{
              writers: [
                %{writer_id: "writer-a", seq: 1, entry_id: "a1"},
                %{writer_id: "writer-b", seq: 1, entry_id: "b1"},
                %{writer_id: "writer-c", seq: 1, entry_id: "c1"}
              ]
            }} = LocalSQLite.frontier(store, @log_id)

    close_store(store)
  end

  test "read_writer ranges are exclusive/inclusive and clamp beyond the tip", %{
    data_dir: data_dir
  } do
    store = initialized_store(data_dir)
    insert_writer_range(store, "writer-a", 1..5)

    assert writer_seqs(store, after_seq: 0, through_seq: 1, limit: 10) == [1]
    assert writer_seqs(store, after_seq: 1, through_seq: 4, limit: 10) == [2, 3, 4]
    assert writer_seqs(store, after_seq: 3, through_seq: 99, limit: 10) == [4, 5]
    assert writer_seqs(store, after_seq: 0, through_seq: nil, limit: 10) == [1, 2, 3, 4, 5]
    close_store(store)
  end

  test "read_writer cursor pages reassemble without gaps or overlap and exact limit ends", %{
    data_dir: data_dir
  } do
    store = initialized_store(data_dir)
    insert_writer_range(store, "writer-a", 1..5)

    assert {:ok, unpaged} =
             LocalSQLite.read_writer(store, @log_id, "writer-a",
               after_seq: 0,
               through_seq: 5,
               limit: 10
             )

    assert {:ok, page1} =
             LocalSQLite.read_writer(store, @log_id, "writer-a",
               after_seq: 0,
               through_seq: 5,
               limit: 2
             )

    assert page1.next_after_seq == 2

    assert {:ok, page2} =
             LocalSQLite.read_writer(store, @log_id, "writer-a",
               after_seq: page1.next_after_seq,
               through_seq: 5,
               limit: 3
             )

    assert page2.next_after_seq == nil
    assert page1.entries ++ page2.entries == unpaged.entries
    close_store(store)
  end

  test "tail_local follows non-coordinate arrival order and resumes with its arrival cursor", %{
    data_dir: data_dir
  } do
    store = initialized_store(data_dir)

    rows = [
      row("writer-z", 2, "z2", "z2"),
      row("writer-a", 1, "a1", "a1"),
      row("writer-z", 3, "z3", "z3")
    ]

    assert {:ok, 1} = LocalSQLite.commit(store, plan(0, Enum.take(rows, 2)))

    assert :ok =
             Sqlite3.execute(
               store.conn,
               "UPDATE sqlite_sequence SET seq = 10 WHERE name = 'entries'"
             )

    assert {:ok, 2} = LocalSQLite.commit(store, plan(1, Enum.drop(rows, 2)))

    coordinate_order =
      rows |> Enum.sort_by(&{&1.writer_id, &1.writer_seq}) |> Enum.map(& &1.canonical_bytes)

    arrival_order = Enum.map(rows, & &1.canonical_bytes)
    refute arrival_order == coordinate_order

    assert {:ok, page1} = LocalSQLite.tail_local(store, @log_id, after_arrival: 0, limit: 2)
    assert Enum.map(page1.entries, & &1.canonical_bytes) == ["z2", "a1"]
    assert page1.next_after_arrival == List.last(page1.entries).arrival_seq

    assert {:ok, page2} =
             LocalSQLite.tail_local(store, @log_id,
               after_arrival: page1.next_after_arrival,
               limit: 2
             )

    assert Enum.map(page2.entries, & &1.canonical_bytes) == ["z3"]
    assert Enum.map(page1.entries ++ page2.entries, & &1.arrival_seq) == [1, 2, 11]
    assert page2.next_after_arrival == nil
    close_store(store)
  end

  test "LocalSQLite and InMemoryPersistence produce the same ReadSet for identical operations", %{
    data_dir: data_dir
  } do
    # This checks substitutability at the Engine boundary: identical create,
    # commit, and selective-read operations yield identical ReadSet values.
    sqlite = initialized_store(data_dir)
    {:ok, memory} = InMemoryPersistence.start_link()
    assert :ok = InMemoryPersistence.create_log(memory, @log_id, %{format_version: 1})

    rows = [row("writer-b", 1, "b1", <<1, 2>>), row("writer-a", 1, "a1", <<3, 4>>)]
    commit_plan = plan(0, rows)

    assert LocalSQLite.commit(sqlite, commit_plan) ==
             InMemoryPersistence.commit(memory, commit_plan)

    query = %{writers: ["writer-a", "missing"], coordinates: [{"writer-b", 1}], entry_ids: ["a1"]}

    assert LocalSQLite.read_set(sqlite, @log_id, query) ==
             InMemoryPersistence.read_set(memory, @log_id, query)

    close_store(sqlite)
  end

  defp open_store(data_dir) do
    assert {:ok, store} = LocalSQLite.open(data_dir, @log_id)
    store
  end

  defp initialized_store(data_dir) do
    store = open_store(data_dir)
    assert :ok = LocalSQLite.create_log(store, @log_id, %{format_version: 1})
    store
  end

  defp close_store(store), do: assert(:ok = LocalSQLite.close(store))

  defp row(writer_id, writer_seq, entry_id, canonical_bytes) do
    %{
      log_id: @log_id,
      entry_id: entry_id,
      writer_id: writer_id,
      writer_seq: writer_seq,
      prev_entry_id: nil,
      created_at: "2026-08-22T12:34:56Z",
      canonical_bytes: canonical_bytes
    }
  end

  defp plan(revision, rows, lease_epoch \\ 0) do
    %CommitPlan{
      log_id: @log_id,
      expected_revision: revision,
      expected_epoch: lease_epoch,
      insert_entries: rows,
      put_tips: tips(rows)
    }
  end

  defp tips(rows) do
    rows
    |> Enum.group_by(& &1.writer_id)
    |> Enum.map(fn {writer_id, writer_rows} ->
      last = Enum.max_by(writer_rows, & &1.writer_seq)
      %{writer_id: writer_id, seq: last.writer_seq, entry_id: last.entry_id}
    end)
  end

  defp empty_read(store) do
    LocalSQLite.read_set(store, @log_id, %{writers: [], coordinates: [], entry_ids: []})
  end

  defp insert_writer_range(store, writer_id, range) do
    rows =
      Enum.map(range, fn seq -> row(writer_id, seq, "#{writer_id}-#{seq}", "bytes-#{seq}") end)

    assert {:ok, 1} = LocalSQLite.commit(store, plan(0, rows))
  end

  defp writer_seqs(store, opts) do
    assert {:ok, %{entries: entries}} = LocalSQLite.read_writer(store, @log_id, "writer-a", opts)
    Enum.map(entries, & &1.writer_seq)
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
end
