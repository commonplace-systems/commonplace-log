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

  test "prepare and commit land an ordered batch without exposing lane identity", %{
    log_id: log_id
  } do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])

    assert {:ok, prepared} =
             DocumentProfile.prepare_append(
               handle,
               [%{"kind" => "commit"}, %{"kind" => "select_head"}],
               operation_id: "operation-1",
               created_at: @created_at
             )

    refute inspect(prepared) =~ "writer"
    refute Map.has_key?(prepared, :writer_id)
    refute Map.has_key?(prepared, :canonical_entries)
    assert {:ok, receipt} = DocumentProfile.commit_prepared(handle, prepared)
    refute Map.has_key?(receipt, :writer_id)
    assert receipt.inserted == 2

    assert [_first, _second] = stored_bytes(log_id)
  end

  test "committing the same prepared append twice stores exactly one copy", %{log_id: log_id} do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])

    assert {:ok, prepared} =
             DocumentProfile.prepare_append(
               handle,
               [%{"kind" => "once"}],
               operation_id: "operation-retry",
               created_at: @created_at
             )

    assert {:ok, %{inserted: 1, present: 0}} =
             DocumentProfile.commit_prepared(handle, prepared)

    assert {:ok, %{inserted: 0, present: 1}} =
             DocumentProfile.commit_prepared(handle, prepared)

    assert [_only_row] = stored_bytes(log_id)
  end

  test "a prepared payload cannot be substituted", %{log_id: log_id} do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])

    assert {:ok, prepared} =
             DocumentProfile.prepare_append(
               handle,
               [%{"kind" => "sealed"}],
               operation_id: "sealed-operation",
               created_at: @created_at
             )

    substituted = Map.update!(prepared, :ciphertext, &(&1 <> <<0>>))

    assert {:error, {:invalid_prepared_append, %{reason: :invalid_prepared_payload}}} =
             DocumentProfile.commit_prepared(handle, substituted)

    assert stored_bytes(log_id) == []
  end

  test "re-preparing identical inputs after an ambiguous commit reproduces exact bytes", %{
    log_id: log_id
  } do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])
    bodies = [%{"kind" => "commit"}, %{"kind" => "select_head"}]
    opts = [operation_id: "operation-after-crash", created_at: @created_at]

    assert {:ok, prepared_before_crash} = DocumentProfile.prepare_append(handle, bodies, opts)

    assert {:ok, %{inserted: 2}} =
             DocumentProfile.commit_prepared(handle, prepared_before_crash)

    landed_before_retry = stored_bytes(log_id)
    prepared_before_crash = nil
    assert is_nil(prepared_before_crash)

    assert {:ok, prepared_after_crash} = DocumentProfile.prepare_append(handle, bodies, opts)

    assert {:ok, %{inserted: 0, present: 2}} =
             DocumentProfile.commit_prepared(handle, prepared_after_crash)

    assert stored_bytes(log_id) == landed_before_retry
    assert length(stored_bytes(log_id)) == 2
  end

  test "re-preparing while an ambiguous request is in flight keeps the occupied coordinate exact",
       %{
         log_id: log_id
       } do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])
    bodies = [%{"kind" => "retry"}]
    opts = [operation_id: "operation-in-flight", created_at: @created_at]

    assert {:ok, in_flight} = DocumentProfile.prepare_append(handle, bodies, opts)
    assert {:ok, recovered} = DocumentProfile.prepare_append(handle, bodies, opts)

    assert {:ok, %{inserted: 1}} = DocumentProfile.commit_prepared(handle, in_flight)

    assert {:ok, %{inserted: 0, present: 1}} =
             DocumentProfile.commit_prepared(handle, recovered)

    assert [_only_row] = stored_bytes(log_id)
  end

  test "same operation id with different bodies at an occupied coordinate is a writer fork", %{
    log_id: log_id
  } do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])
    opts = [operation_id: "reused-operation", created_at: @created_at]

    assert {:ok, first} = DocumentProfile.prepare_append(handle, [%{"value" => 1}], opts)
    assert {:ok, conflicting} = DocumentProfile.prepare_append(handle, [%{"value" => 2}], opts)
    assert {:ok, %{inserted: 1}} = DocumentProfile.commit_prepared(handle, first)

    assert {:error, {:writer_fork, %{seq: 1}}} =
             DocumentProfile.commit_prepared(handle, conflicting)

    assert [only] = decoded_rows(log_id)
    assert only["body"] == %{"value" => 1}
  end

  test "a failed two-entry batch leaves no partial prefix", %{log_id: log_id} do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])

    assert {:ok, batch} =
             DocumentProfile.prepare_append(
               handle,
               [%{"batch" => 1}, %{"batch" => 2}],
               operation_id: "batch-operation",
               created_at: @created_at
             )

    assert {:ok, rival} =
             DocumentProfile.prepare_append(
               handle,
               [%{"rival" => true}],
               operation_id: "rival-operation",
               created_at: @created_at
             )

    assert {:ok, %{inserted: 1}} = DocumentProfile.commit_prepared(handle, rival)
    assert {:error, {:writer_fork, %{seq: 1}}} = DocumentProfile.commit_prepared(handle, batch)

    assert [%{"body" => %{"rival" => true}}] =
             Enum.map(decoded_rows(log_id), &Map.take(&1, ["body"]))
  end

  test "append_batch has the same exact retry behavior", %{log_id: log_id} do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])
    bodies = [%{"n" => 1}, %{"n" => 2}]
    opts = [operation_id: "append-batch-retry", created_at: @created_at]

    assert {:ok, %{inserted: 2, present: 0}} =
             DocumentProfile.append_batch(handle, bodies, opts)

    first_rows = stored_bytes(log_id)

    assert {:ok, %{inserted: 0, present: 2}} =
             DocumentProfile.append_batch(handle, bodies, opts)

    assert stored_bytes(log_id) == first_rows
    assert length(first_rows) == 2
  end

  test "a prepared batch held across lease handoff is fenced and writes nothing", %{
    log_id: log_id
  } do
    assert {:ok, first_handle} = DocumentProfile.create_log(log_id, [])

    assert {:ok, prepared} =
             DocumentProfile.prepare_append(
               first_handle,
               [%{"n" => 1}, %{"n" => 2}],
               operation_id: "stale-prepared",
               created_at: @created_at
             )

    assert {:ok, _second_handle} = DocumentProfile.open_log(log_id, [])

    result = DocumentProfile.commit_prepared(first_handle, prepared)

    assert stored_bytes(log_id) == []

    assert {:error, {:writer_lease_fenced, %{}}} = result
  end

  test "prepared append requires stable operation id and created_at inputs", %{log_id: log_id} do
    assert {:ok, handle} = DocumentProfile.create_log(log_id, [])

    assert {:error, {:invalid_prepared_append, %{reason: :operation_id_required}}} =
             DocumentProfile.prepare_append(handle, [%{"n" => 1}], created_at: @created_at)

    assert {:error, {:invalid_prepared_append, %{reason: :created_at_required}}} =
             DocumentProfile.prepare_append(handle, [%{"n" => 1}], operation_id: "missing-time")
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

    assert Enum.sort(public_api) ==
             [
               append: 3,
               append_batch: 3,
               commit_prepared: 2,
               create_log: 2,
               open_log: 2,
               prepare_append: 3
             ]

    refute function_exported?(DocumentProfile, :append, 4)
    refute function_exported?(DocumentProfile, :append_batch, 4)
    refute function_exported?(DocumentProfile, :commit_prepared, 3)
    refute function_exported?(DocumentProfile, :create_log, 3)
    refute function_exported?(DocumentProfile, :open_log, 3)
    refute function_exported?(DocumentProfile, :prepare_append, 4)
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

  defp stored_bytes(log_id) do
    assert {:ok, %{entries: entries, next_after_arrival: nil}} =
             SQLite.tail_local(log_id, after_arrival: 0, limit: 100)

    Enum.map(entries, & &1.canonical_bytes)
  end

  defp decoded_rows(log_id), do: Enum.map(stored_bytes(log_id), &Jason.decode!/1)

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
