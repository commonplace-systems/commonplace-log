defmodule Commonplace.Log.DocumentProfileTest do
  use ExUnit.Case, async: false

  alias Commonplace.Log.{DocumentProfile, Engine, UUID}
  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.LogStore.SQLite
  alias Exqlite.Sqlite3

  @created_at ~U[2026-08-22 12:34:56Z]

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "commonplace-document-profile-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)
    previous = Application.get_env(:commonplace_log, SQLite)
    Application.put_env(:commonplace_log, SQLite, data_dir: data_dir)

    on_exit(fn ->
      stop_all_servers()

      if previous do
        Application.put_env(:commonplace_log, SQLite, previous)
      else
        Application.delete_env(:commonplace_log, SQLite)
      end

      File.rm_rf!(data_dir)
    end)

    %{data_dir: data_dir, log_id: UUID.uuidv7()}
  end

  test "create, append, and read back without exposing a writer id", %{log_id: log_id} do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])

    assert {:ok, result} =
             DocumentProfile.append(handle, %{"kind" => "note"}, created_at: @created_at)

    refute Map.has_key?(result, :writer_id)
    assert result.writer_seq == 1

    assert {:ok, %{entries: [%{canonical_bytes: bytes}]}} =
             SQLite.tail_local(log_id, after_arrival: 0, limit: 10)

    assert Jason.decode!(bytes)["body"] == %{"kind" => "note"}
  end

  test "three appends use one durable lane and chain sequence 1, 2, 3", %{log_id: log_id} do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])

    results =
      for n <- 1..3 do
        assert {:ok, result} =
                 DocumentProfile.append(handle, %{"n" => n}, created_at: @created_at)

        result
      end

    assert Enum.map(results, & &1.writer_seq) == [1, 2, 3]
    assert {:ok, %{writers: [%{seq: 3}]}} = SQLite.frontier(log_id)
  end

  test "the durable lane and next sequence survive a server restart", %{log_id: log_id} do
    assert {:ok, first_handle} = DocumentProfile.create_log(log_id, [])
    assert {:ok, %{writer_seq: 1}} = DocumentProfile.append(first_handle, %{"n" => 1}, [])
    writer_before = only_writer(log_id)

    stop_server(log_id)

    assert {:ok, reopened_handle} = DocumentProfile.open_log(log_id, [])
    assert {:ok, %{writer_seq: 2}} = DocumentProfile.append(reopened_handle, %{"n" => 2}, [])
    assert only_writer(log_id) == writer_before
  end

  test "an obsolete activation cannot append after lease handoff", %{log_id: log_id} do
    assert {:ok, first_handle} = DocumentProfile.create_log(log_id, [])
    assert {:ok, %{writer_seq: 1}} = DocumentProfile.append(first_handle, %{"n" => 1}, [])
    writer_id = only_writer(log_id)

    assert {:ok, second_handle} = DocumentProfile.open_log(log_id, [])

    assert {:error, {:writer_lease_fenced, %{}}} =
             DocumentProfile.append(first_handle, %{"must_not_write" => true}, [])

    assert {:ok, %{writers: [%{writer_id: ^writer_id, seq: 1}]}} = SQLite.frontier(log_id)

    assert {:ok, %{writer_seq: 2}} =
             DocumentProfile.append(second_handle, %{"n" => 2}, [])

    assert {:ok, %{writers: [%{writer_id: ^writer_id, seq: 2}]}} = SQLite.frontier(log_id)
  end

  test "opening a never-created log returns log_not_found and creates nothing", %{
    data_dir: data_dir,
    log_id: log_id
  } do
    before = directory_listing(data_dir)

    assert DocumentProfile.open_log(log_id, []) == {:error, {:log_not_found, %{}}}
    assert directory_listing(data_dir) == before
  end

  test "a held local lock maps to writer_lease_unavailable", %{
    data_dir: data_dir,
    log_id: log_id
  } do
    assert {:ok, _handle} = DocumentProfile.create_log(log_id, [])
    stop_server(log_id)

    lock_path = Path.join(data_dir, log_id <> ".lock.sqlite3")
    assert {:ok, lock_conn} = Sqlite3.open(lock_path)
    assert :ok = Sqlite3.execute(lock_conn, "BEGIN EXCLUSIVE")

    assert {:error, {:writer_lease_unavailable, %{}}} = DocumentProfile.open_log(log_id, [])

    assert :ok = Sqlite3.execute(lock_conn, "ROLLBACK")
    assert :ok = Sqlite3.close(lock_conn)
  end

  test "creation is idempotent and persists its identity before acknowledging", %{
    data_dir: data_dir,
    log_id: log_id
  } do
    writer_path = Path.join(data_dir, log_id <> ".writer")
    refute File.exists?(writer_path)

    assert {:ok, _handle} = DocumentProfile.create_log(log_id, [])
    first_identity = File.read!(writer_path)
    assert first_identity != ""

    assert {:ok, _handle} = DocumentProfile.create_log(log_id, [])
    assert File.read!(writer_path) == first_identity
  end

  test "ordinary activation refuses a genuine multi-lane protocol log", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    [{server, _}] = Registry.lookup(Commonplace.LogStore.SQLite.Registry, log_id)
    %{store: store} = :sys.get_state(server)

    assert {:ok, %{writer_seq: 1}} =
             Engine.append(LocalSQLite, store, log_id, UUID.uuidv7(), %{"lane" => 1}, @created_at)

    assert {:ok, %{writer_seq: 1}} =
             Engine.append(LocalSQLite, store, log_id, UUID.uuidv7(), %{"lane" => 2}, @created_at)

    assert {:error, {:multiwriter_document_unsupported, %{writer_count: 2}}} =
             DocumentProfile.open_log(log_id, [])

    # The same history remains legal and writable through the base protocol surface.
    assert {:ok, %{inserted: 1}} = SQLite.merge(log_id, chain(log_id, UUID.uuidv7()))
    assert {:ok, %{writers: writers}} = SQLite.frontier(log_id)
    assert length(writers) == 3
  end

  test "the public façade has no lane-selection or rekey operation" do
    public_api =
      DocumentProfile.__info__(:functions)
      |> Enum.reject(fn {name, _arity} -> name in [:__struct__] end)

    assert Enum.sort(public_api) == [append: 3, create_log: 2, open_log: 2]
    refute function_exported?(DocumentProfile, :append, 4)
    refute function_exported?(DocumentProfile, :create_log, 3)
    refute function_exported?(DocumentProfile, :open_log, 3)
    refute function_exported?(DocumentProfile, :rekey, 1)
  end

  defp only_writer(log_id) do
    assert {:ok, %{writers: [%{writer_id: writer_id}]}} = SQLite.frontier(log_id)
    writer_id
  end

  defp chain(log_id, writer_id) do
    [
      %{
        "version" => 1,
        "log_id" => log_id,
        "entry_id" => UUID.uuidv7(),
        "writer_id" => writer_id,
        "writer_seq" => 1,
        "prev_entry_id" => nil,
        "created_at" => DateTime.to_iso8601(@created_at),
        "body" => %{"base_protocol" => true}
      }
    ]
  end

  defp directory_listing(data_dir), do: data_dir |> File.ls!() |> Enum.sort()

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
