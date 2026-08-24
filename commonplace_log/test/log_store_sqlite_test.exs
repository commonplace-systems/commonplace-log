defmodule Commonplace.LogStore.SQLiteTest do
  use ExUnit.Case, async: false

  alias Commonplace.Log.{Frontier, UUID}
  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.LogStore.SQLite
  alias Exqlite.Sqlite3

  @created_at ~U[2026-08-22 12:34:56Z]
  @protocol_codes ~w(writer_gap writer_fork entry_id_collision invalid_entry entry_too_large log_mismatch log_not_found)a

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "commonplace-log-store-#{System.unique_integer([:positive])}")

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

  test "missing-log operations return log_not_found without changing the data directory", %{
    data_dir: data_dir
  } do
    operations = [
      frontier: &SQLite.frontier/1,
      frontier_value: &SQLite.frontier_value/1,
      read_through: &SQLite.read_through(&1, Frontier.new([]), []),
      read_writer: &SQLite.read_writer(&1, UUID.uuidv7(), after_seq: 0, limit: 10),
      tail_local: &SQLite.tail_local(&1, after_arrival: 0, limit: 10),
      append: &SQLite.append(&1, UUID.uuidv7(), %{"missing" => true}, @created_at),
      merge: &SQLite.merge(&1, [])
    ]

    Enum.each(operations, fn {operation, call} ->
      log_id = UUID.uuidv7()
      before = directory_listing(data_dir)
      result = call.(log_id)
      after_call = directory_listing(data_dir)

      assert after_call == before,
             "#{operation} created durable files for a missing log; " <>
               "before=#{inspect(before)} after=#{inspect(after_call)}"

      assert result == {:error, {:log_not_found, %{}}},
             "#{operation} should reject a missing log"
    end)
  end

  test "a created empty log is distinguishable from a missing log", %{
    data_dir: data_dir,
    log_id: log_id
  } do
    missing_log = UUID.uuidv7()
    before = directory_listing(data_dir)
    missing_result = SQLite.frontier(missing_log)
    after_missing_read = directory_listing(data_dir)

    assert after_missing_read == before
    assert missing_result == {:error, {:log_not_found, %{}}}

    assert :ok = SQLite.create_log(log_id)
    assert {:ok, %{writers: []}} = SQLite.frontier(log_id)
    assert File.exists?(Path.join(data_dir, log_id <> ".writer"))
  end

  test "two concurrent reads of one missing log both fail without creating files", %{
    data_dir: data_dir,
    log_id: log_id
  } do
    before = directory_listing(data_dir)

    results =
      1..2
      |> Task.async_stream(fn _ -> SQLite.frontier(log_id) end,
        max_concurrency: 2,
        ordered: false
      )
      |> Enum.map(fn {:ok, result} -> result end)

    assert directory_listing(data_dir) == before

    assert results == [
             {:error, {:log_not_found, %{}}},
             {:error, {:log_not_found, %{}}}
           ]
  end

  test "a read concurrent with create either precedes it or joins the created log", %{
    log_id: log_id
  } do
    create = Task.async(fn -> SQLite.create_log(log_id) end)
    read = Task.async(fn -> SQLite.frontier(log_id) end)

    assert Task.await(create) == :ok

    assert Task.await(read) in [
             {:error, {:log_not_found, %{}}},
             {:ok, %{writers: []}}
           ]

    assert {:ok, %{writers: []}} = SQLite.frontier(log_id)
  end

  test "create_log is idempotent and normalizes a stored identity mismatch", %{
    data_dir: data_dir,
    log_id: log_id
  } do
    assert :ok = SQLite.create_log(log_id)
    writer_path = Path.join(data_dir, log_id <> ".writer")
    writer_id = File.read!(writer_path)

    assert writer_id != ""
    assert :ok = SQLite.create_log(log_id)
    assert File.read!(writer_path) == writer_id
    stop_server(log_id)

    other_log = UUID.uuidv7()

    File.cp!(
      Path.join(data_dir, log_id <> ".sqlite3"),
      Path.join(data_dir, other_log <> ".sqlite3")
    )

    assert_protocol_error(SQLite.create_log(other_log), :log_mismatch)
  end

  test "append returns the server-owned identity and a 1,2,3 sequence", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)

    results =
      for n <- 1..3 do
        assert {:ok, result} =
                 SQLite.append(log_id, "not-the-local-identity", %{"n" => n}, @created_at)

        result
      end

    assert Enum.map(results, & &1.writer_seq) == [1, 2, 3]
    assert results |> Enum.map(& &1.writer_id) |> Enum.uniq() |> length() == 1
    assert Enum.all?(results, &is_binary(&1.entry_id))
  end

  test "merge inserts a fresh chain and reports an identical re-merge as present", %{
    log_id: log_id
  } do
    assert :ok = SQLite.create_log(log_id)
    entries = chain(log_id, UUID.uuidv7(), 3)
    assert {:ok, %{inserted: 3, present: 0}} = SQLite.merge(log_id, entries)
    assert {:ok, %{inserted: 0, present: 3}} = SQLite.merge(log_id, entries)
  end

  test "writer_gap has the one public error shape", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    [entry] = chain(log_id, UUID.uuidv7(), 1, start_seq: 2, prev: UUID.uuidv7())
    assert_protocol_error(SQLite.merge(log_id, [entry]), :writer_gap)
  end

  test "writer_fork has the one public error shape", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    writer = UUID.uuidv7()
    [original] = chain(log_id, writer, 1)
    assert {:ok, _} = SQLite.merge(log_id, [original])

    fork = %{original | "entry_id" => UUID.uuidv7(), "body" => %{"fork" => true}}
    assert_protocol_error(SQLite.merge(log_id, [fork]), :writer_fork)
  end

  test "entry_id_collision has the one public error shape", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    [original] = chain(log_id, UUID.uuidv7(), 1)
    assert {:ok, _} = SQLite.merge(log_id, [original])

    [other] = chain(log_id, UUID.uuidv7(), 1)
    collision = %{other | "entry_id" => original["entry_id"]}
    assert_protocol_error(SQLite.merge(log_id, [collision]), :entry_id_collision)
  end

  test "invalid_entry keeps the validator reason slug in the normalized map", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    [entry] = chain(log_id, UUID.uuidv7(), 1)
    invalid = %{entry | "entry_id" => "malformed-uuid"}

    assert {:error, {:invalid_entry, %{reason: "uuid-malformed"}}} =
             SQLite.merge(log_id, [invalid])
  end

  test "entry_too_large has the one public error shape", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    [entry] = chain(log_id, UUID.uuidv7(), 1)
    oversized = %{entry | "body" => %{"text" => String.duplicate("x", 1_048_576)}}

    assert {:error, {:entry_too_large, %{reason: "canonical-bytes-over-1mib"}}} =
             SQLite.merge(log_id, [oversized])
  end

  test "a genuine SQLite failure is storage, not protocol", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    [{server, _}] = Registry.lookup(Commonplace.LogStore.SQLite.Registry, log_id)
    %{store: store} = :sys.get_state(server)

    # Deliberately remove a table behind the adapter's live connection so its
    # next real SQLite query fails with "no such table".
    assert :ok = Sqlite3.execute(store.conn, "DROP TABLE writer_tips")

    assert {:error, {:storage, %{reason: reason}}} = SQLite.frontier(log_id)
    assert is_binary(reason)
    assert :storage not in @protocol_codes
  end

  test "a missing stored log is normalized as log_not_found", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    [{server, _}] = Registry.lookup(Commonplace.LogStore.SQLite.Registry, log_id)
    %{store: store} = :sys.get_state(server)

    # Simulate a store whose singleton log record has gone missing while its
    # schema and open handle remain otherwise valid.
    assert :ok = Sqlite3.execute(store.conn, "DELETE FROM log_meta")

    assert_protocol_error(SQLite.frontier(log_id), :log_not_found)
  end

  test "frontier sorts at least three writers by writer_id", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    writers = Enum.map(1..3, fn _ -> UUID.uuidv7() end)
    assert {:ok, _} = SQLite.merge(log_id, Enum.flat_map(writers, &chain(log_id, &1, 1)))
    assert {:ok, %{writers: frontier}} = SQLite.frontier(log_id)
    assert Enum.map(frontier, & &1.writer_id) == Enum.sort(writers)
  end

  test "frontier operations dispatch by log_id and match their bound-map forms", %{
    log_id: log_id
  } do
    assert :ok = SQLite.create_log(log_id)
    writers = Enum.map(1..2, fn _ -> UUID.uuidv7() end)
    assert {:ok, _} = SQLite.merge(log_id, Enum.flat_map(writers, &chain(log_id, &1, 2)))

    [{server, _}] = Registry.lookup(Commonplace.LogStore.SQLite.Registry, log_id)
    %{store: store} = :sys.get_state(server)
    bound_log = %{module: LocalSQLite, store: store, log_id: log_id}

    assert {:ok, frontier} = Frontier.frontier_value(bound_log)
    assert SQLite.frontier_value(log_id) == {:ok, frontier}

    assert SQLite.read_through(log_id, frontier, page_size: 1) ==
             Frontier.read_through(bound_log, frontier, page_size: 1)
  end

  test "unknown frontier tips keep their typed error through dispatch", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    unknown_tip = UUID.uuidv7()

    assert {:error,
            %Frontier.Error{
              operation: :verify,
              reason: :unknown_tip,
              entry_id: ^unknown_tip
            }} = SQLite.read_through(log_id, Frontier.new([unknown_tip]), [])
  end

  test "frontier operation successes and errors never expose LocalSQLite", %{
    log_id: log_id
  } do
    assert :ok = SQLite.create_log(log_id)
    assert {:ok, appended} = SQLite.append(log_id, "ignored", %{"n" => 1}, @created_at)
    frontier = Frontier.new([appended.entry_id])
    missing_log = UUID.uuidv7()

    results = [
      SQLite.frontier_value(log_id),
      SQLite.read_through(log_id, frontier, []),
      SQLite.frontier_value(missing_log),
      SQLite.read_through(missing_log, Frontier.new([]), []),
      SQLite.read_through(log_id, Frontier.new([UUID.uuidv7()]), [])
    ]

    Enum.each(results, fn result ->
      refute contains_local_sqlite?(result),
             "LocalSQLite escaped in #{inspect(result)}"
    end)
  end

  test "read_writer is exclusive/inclusive and cursor pages equal one unpaged read", %{
    log_id: log_id
  } do
    assert :ok = SQLite.create_log(log_id)
    writer = UUID.uuidv7()
    assert {:ok, _} = SQLite.merge(log_id, chain(log_id, writer, 5))

    assert {:ok, unpaged} =
             SQLite.read_writer(log_id, writer, after_seq: 1, through_seq: 5, limit: 10)

    assert Enum.map(unpaged.entries, & &1.writer_seq) == [2, 3, 4, 5]
    assert unpaged.next_after_seq == nil

    assert {:ok, first} =
             SQLite.read_writer(log_id, writer, after_seq: 1, through_seq: 5, limit: 2)

    assert first.next_after_seq == 3

    assert {:ok, second} =
             SQLite.read_writer(log_id, writer,
               after_seq: first.next_after_seq,
               through_seq: 5,
               limit: 2
             )

    assert first.entries ++ second.entries == unpaged.entries
    assert second.next_after_seq == nil
  end

  test "tail_local preserves arrival order and pages with its cursor", %{log_id: log_id} do
    assert :ok = SQLite.create_log(log_id)
    writers = Enum.map(1..3, fn _ -> UUID.uuidv7() end)

    Enum.each(writers, fn writer ->
      assert {:ok, _} = SQLite.merge(log_id, chain(log_id, writer, 1))
    end)

    assert {:ok, all} = SQLite.tail_local(log_id, after_arrival: 0, limit: 10)
    assert Enum.map(all.entries, & &1.arrival_seq) == [1, 2, 3]

    assert {:ok, first} = SQLite.tail_local(log_id, after_arrival: 0, limit: 2)
    assert first.next_after_arrival == 2
    assert {:ok, second} = SQLite.tail_local(log_id, after_arrival: 2, limit: 2)
    assert first.entries ++ second.entries == all.entries
    assert second.next_after_arrival == nil
  end

  test "two logs in one data directory do not share writers", %{log_id: first_log} do
    second_log = UUID.uuidv7()
    first_writer = UUID.uuidv7()
    second_writer = UUID.uuidv7()

    assert :ok = SQLite.create_log(first_log)
    assert :ok = SQLite.create_log(second_log)

    assert {:ok, _} = SQLite.merge(first_log, chain(first_log, first_writer, 1))
    assert {:ok, _} = SQLite.merge(second_log, chain(second_log, second_writer, 1))
    assert {:ok, %{writers: [%{writer_id: ^first_writer}]}} = SQLite.frontier(first_log)
    assert {:ok, %{writers: [%{writer_id: ^second_writer}]}} = SQLite.frontier(second_log)
  end

  defp chain(log_id, writer_id, count, opts \\ []) do
    start_seq = Keyword.get(opts, :start_seq, 1)
    first_prev = Keyword.get(opts, :prev)

    Enum.map_reduce(start_seq..(start_seq + count - 1), first_prev, fn seq, prev ->
      entry_id = UUID.uuidv7()

      entry = %{
        "version" => 1,
        "log_id" => log_id,
        "entry_id" => entry_id,
        "writer_id" => writer_id,
        "writer_seq" => seq,
        "prev_entry_id" => prev,
        "created_at" => DateTime.to_iso8601(@created_at),
        "body" => %{"seq" => seq}
      }

      {entry, entry_id}
    end)
    |> elem(0)
  end

  defp assert_protocol_error(result, expected_code) do
    assert {:error, {code, details}} = result
    assert code == expected_code
    assert code in @protocol_codes
    assert is_map(details)
  end

  defp contains_local_sqlite?(%LocalSQLite{}), do: true

  defp contains_local_sqlite?(value) when is_map(value) do
    value
    |> Map.to_list()
    |> Enum.any?(fn {key, item} ->
      contains_local_sqlite?(key) or contains_local_sqlite?(item)
    end)
  end

  defp contains_local_sqlite?(value) when is_list(value),
    do: Enum.any?(value, &contains_local_sqlite?/1)

  defp contains_local_sqlite?(value) when is_tuple(value),
    do: value |> Tuple.to_list() |> Enum.any?(&contains_local_sqlite?/1)

  defp contains_local_sqlite?(_value), do: false

  defp directory_listing(data_dir), do: data_dir |> File.ls!() |> Enum.sort()

  defp stop_server(log_id) do
    case Registry.lookup(Commonplace.LogStore.SQLite.Registry, log_id) do
      [{server, _}] ->
        if Process.alive?(server), do: GenServer.stop(server), else: :ok

      [] ->
        :ok
    end
  end

  defp stop_all_servers do
    if Process.whereis(Commonplace.LogStore.SQLite.Registry) do
      Registry.select(Commonplace.LogStore.SQLite.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(&stop_server/1)
    end
  end
end
