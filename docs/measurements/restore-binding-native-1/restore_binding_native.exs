out = Path.expand(List.first(System.argv()) || raise("output directory argument required"))
root = Path.expand("../../..", __DIR__)

beam_root = System.get_env("RESTORE_BINDING_BEAM_ROOT")

if beam_root do
  Path.wildcard(Path.join(beam_root, "*/ebin"))
  |> Enum.sort()
  |> Enum.each(&Code.prepend_path/1)
end

dep_ebin = Path.join(out, "dependency-ebin")
app_ebin = Path.join(out, "app-ebin")
File.mkdir_p!(dep_ebin)
File.mkdir_p!(app_ebin)

{:ok, _, _} =
  Kernel.ParallelCompiler.compile_to_path(
    Path.wildcard(Path.join(root, "commonplace_log/lib/**/*.ex")),
    app_ebin
  )

Code.prepend_path(app_ebin)

Application.ensure_all_started(:commonplace_log)

ExUnit.start(autorun: false, exclude: [], include: [])

defmodule RestoreBindingNativeTest do
  use ExUnit.Case, async: false

  alias Commonplace.Log.{DocumentProfile, Engine, Frontier, UUID}
  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.LogStore.SQLite
  alias Commonplace.LogStore.SQLite.Restore
  alias Commonplace.LogStore.SQLite.Server
  alias Exqlite.Sqlite3

  @created_at ~U[2026-08-22 12:34:56Z]

  setup do
    source_dir = fresh_dir("source")
    Application.put_env(:commonplace_log, SQLite, data_dir: source_dir)

    on_exit(fn ->
      stop_all_servers()
      File.rm_rf!(source_dir)
    end)

    %{source_dir: source_dir, log_id: UUID.uuidv7()}
  end

  test "existing DocumentProfile lane keeps one writer across restart", %{log_id: log_id} do
    assert {:ok, first} = DocumentProfile.create_log(log_id, [])
    assert {:ok, %{writer_seq: 1}} = DocumentProfile.append(first, %{"n" => 1}, [])
    writer = only_writer(log_id)
    stop_server(log_id)

    assert {:ok, reopened} = DocumentProfile.open_log(log_id, [])
    assert {:ok, %{writer_seq: 2}} = DocumentProfile.append(reopened, %{"n" => 2}, [])
    assert ^writer = only_writer(log_id)
  end

  test "restore preserves bytes and writer, then supports append and restart", %{
    source_dir: source_dir,
    log_id: log_id
  } do
    assert {:ok, source_handle} = DocumentProfile.create_log(log_id, [])

    for n <- 1..4 do
      assert {:ok, %{writer_seq: ^n}} = DocumentProfile.append(source_handle, %{"n" => n}, [])
    end

    assert {:ok, frontier} = SQLite.frontier_value(log_id)
    assert {:ok, source_bytes} = SQLite.read_through(log_id, frontier, [])
    source_writer = only_writer(log_id)
    stop_server(log_id)

    target_dir = fresh_dir("target")
    Application.put_env(:commonplace_log, SQLite, data_dir: target_dir)
    on_exit(fn -> File.rm_rf!(target_dir) end)

    request = SQLite.restore_request(log_id, frontier)
    assert {:ok, target_handle} = DocumentProfile.restore_log(log_id, source_bytes, request)
    assert source_writer == only_writer(log_id)
    assert {:ok, ^source_bytes} = SQLite.read_through(log_id, frontier, [])
    assert {:ok, %{writer_seq: 5}} = DocumentProfile.append(target_handle, %{"n" => 5}, [])

    assert {:error, {:storage, _}} =
             DocumentProfile.append(source_handle, %{"must_not_write_target" => true}, [])

    stop_server(log_id)
    assert {:ok, reopened} = DocumentProfile.open_log(log_id, [])
    assert {:ok, %{writer_seq: 6}} = DocumentProfile.append(reopened, %{"n" => 6}, [])
    assert source_writer == only_writer(log_id)

    File.rm_rf!(source_dir)
  end

  test "pending marker fences ordinary owner calls and resumes without a writer sidecar", %{
    source_dir: source_dir,
    log_id: log_id
  } do
    assert {:ok, source_handle} = DocumentProfile.create_log(log_id, [])
    assert {:ok, %{writer_seq: 1}} = DocumentProfile.append(source_handle, %{"n" => 1}, [])
    assert {:ok, frontier} = SQLite.frontier_value(log_id)
    assert {:ok, entries} = SQLite.read_through(log_id, frontier, [])
    stop_server(log_id)

    target_dir = fresh_dir("pending")
    Application.put_env(:commonplace_log, SQLite, data_dir: target_dir)
    on_exit(fn -> File.rm_rf!(target_dir) end)
    request = SQLite.restore_request(log_id, frontier)
    assert {:ok, spec} = Restore.prepare(log_id, entries, request)

    assert {:ok, store} = LocalSQLite.open(target_dir, log_id)
    assert :ok = LocalSQLite.prepare_restore(store, log_id, spec)
    assert {:ok, lease} = LocalSQLite.take_lease(store, log_id)
    assert {:ok, %{inserted: 1}} = Engine.merge(LocalSQLite, store, log_id, [hd(entries)], lease)
    assert :ok = LocalSQLite.close(store)
    writer_path = Path.join(target_dir, log_id <> ".writer")
    refute File.exists?(writer_path)

    assert {:error, {:storage, %{reason: create_reason}}} = SQLite.create_log(log_id)
    assert inspect(create_reason) =~ "restore_incomplete"
    refute File.exists?(writer_path)
    assert match?({:error, _}, SQLite.frontier(log_id))

    assert {:ok, restored} = DocumentProfile.restore_log(log_id, entries, capability)
    assert File.exists?(writer_path)
    assert {:ok, %{writer_seq: 2}} = DocumentProfile.append(restored, %{"n" => 2}, [])

    File.rm_rf!(source_dir)
  end

  test "restore owner fences pending append, merge, and lease calls", %{log_id: log_id} do
    assert {:ok, source} = DocumentProfile.create_log(log_id, [])
    assert {:ok, %{writer_seq: 1}} = DocumentProfile.append(source, %{"n" => 1}, [])
    assert {:ok, frontier} = SQLite.frontier_value(log_id)
    assert {:ok, entries} = SQLite.read_through(log_id, frontier, [])
    stop_server(log_id)

    target_dir = fresh_dir("owner-pending")
    Application.put_env(:commonplace_log, SQLite, data_dir: target_dir)
    on_exit(fn -> File.rm_rf!(target_dir) end)
    request = SQLite.restore_request(log_id, frontier)
    assert {:ok, spec} = Restore.prepare(log_id, entries, request)
    assert {:ok, owner} = Server.start_link(data_dir: target_dir, log_id: log_id, mode: {:restore, spec})

    assert {:error, :restore_incomplete} = Server.append(owner, %{"blocked" => true}, @created_at)
    assert {:error, :restore_incomplete} = Server.merge(owner, entries)
    assert {:error, :restore_incomplete} = Server.take_lease(owner)
    assert {:ok, %{restored: true}} = Server.restore(owner, entries, spec)
    assert {:ok, lease} = Server.take_lease(owner)
    assert is_integer(lease)
    GenServer.stop(owner)
  end

  test "existing unmarked log is refused without adding restore schema", %{log_id: log_id} do
    assert {:ok, source} = DocumentProfile.create_log(log_id, [])
    assert {:ok, %{writer_seq: 1}} = DocumentProfile.append(source, %{"n" => 1}, [])
    assert {:ok, frontier} = SQLite.frontier_value(log_id)
    assert {:ok, entries} = SQLite.read_through(log_id, frontier, [])
    stop_server(log_id)
    sqlite_path = Path.join(Application.fetch_env!(:commonplace_log, SQLite)[:data_dir], log_id <> ".sqlite3")
    before = sqlite_tables(sqlite_path)

    assert {:error, {:storage, %{reason: refusal_reason}}} =
             DocumentProfile.restore_log(log_id, entries, SQLite.restore_request(log_id, frontier))
    assert inspect(refusal_reason) =~ "restore_target_not_new"

    assert sqlite_tables(sqlite_path) == before
    refute "restore_meta" in before
  end

  defp fresh_dir(label), do: Path.join(System.tmp_dir!(), "restore-binding-native-#{label}-#{System.unique_integer([:positive])}") |> tap(&File.mkdir_p!/1)

  defp only_writer(log_id) do
    assert {:ok, %{writers: [%{writer_id: writer_id}]}} = SQLite.frontier(log_id)
    writer_id
  end

  defp sqlite_tables(path) do
    {:ok, conn} = Sqlite3.open(path)
    {:ok, rows} = query(conn, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
    :ok = Sqlite3.close(conn)
    Enum.map(rows, &hd/1)
  end

  defp query(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    :ok = Sqlite3.bind(stmt, [])
    rows = fetch_rows(conn, stmt, [])
    :ok = Sqlite3.release(conn, stmt)
    {:ok, rows}
  end

  defp fetch_rows(conn, stmt, acc) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_rows(conn, stmt, [row | acc])
      :done -> Enum.reverse(acc)
    end
  end

  defp stop_server(log_id) do
    case Registry.lookup(Commonplace.LogStore.SQLite.Registry, log_id) do
      [{server, _}] -> GenServer.stop(server)
      [] -> :ok
    end
  end

  defp stop_all_servers do
    if Process.whereis(Commonplace.LogStore.SQLite.Registry) do
      Registry.select(Commonplace.LogStore.SQLite.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(&stop_server/1)
    end
  end
end

Code.require_file(Path.join(root, "commonplace_log/test/document_profile_test.exs"))
result = ExUnit.run()
File.write!(Path.join(out, "native-result.raw.json"), Jason.encode!(result))

expected =
  System.get_env("RESTORE_BINDING_EXPECTED_CASES", "")
  |> String.split("\n", trim: true)
  |> Enum.sort()

unless result.total == length(expected) and result.failures == 0 and result.skipped == 0,
  do: raise("native focused suite failed")

File.write!(
  Path.join(out, "native-result.json"),
  Jason.encode!(Map.merge(result, %{"status" => "pass", "cases" => expected}))
)
