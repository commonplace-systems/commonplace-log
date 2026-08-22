defmodule Commonplace.Log.ConformanceTest do
  use ExUnit.Case, async: false

  alias Commonplace.Log.{Engine, Jcs, UUID}
  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.Log.Test.SQLAudit
  alias Commonplace.LogStore.SQLite
  alias Exqlite.Sqlite3

  @created_at "2026-08-22T12:34:56Z"

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "commonplace-conformance-#{System.unique_integer([:positive])}"
      )

    public_dir = Path.join(root, "public")
    File.mkdir_p!(public_dir)

    previous = Application.get_env(:commonplace_log, SQLite)
    Application.put_env(:commonplace_log, SQLite, data_dir: public_dir)

    on_exit(fn ->
      stop_all_servers()

      if previous,
        do: Application.put_env(:commonplace_log, SQLite, previous),
        else: Application.delete_env(:commonplace_log, SQLite)

      File.rm_rf!(root)
    end)

    %{root: root, log_id: UUID.uuidv7()}
  end

  test "§18.1 repeating one append produces one stored entry", %{log_id: log_id} do
    assert {:ok, appended} = SQLite.append(log_id, "ignored", %{"note" => "once"}, @created_at)
    assert {:ok, page} = SQLite.read_writer(log_id, appended.writer_id, after_seq: 0, limit: 10)
    assert [produced] = Enum.map(page.entries, & &1.canonical_bytes)

    # append/4 mints an ID, so a retry means submitting the same produced entry.
    assert {:ok, %{inserted: 0, present: 1}} = SQLite.merge(log_id, [produced])
    assert {:ok, %{inserted: 0, present: 1}} = SQLite.merge(log_id, [produced])
    assert count(public_store(log_id), "entries") == 1
    assert_clean(public_store(log_id))
  end

  test "§18.2 retrying after a simulated lost acknowledgement is idempotent", %{log_id: log_id} do
    entries = chain(log_id, UUID.uuidv7(), 3)
    assert {:ok, first} = SQLite.merge(log_id, entries)
    assert first.inserted == 3

    # Treat the first successful return as lost, then retry the identical bytes.
    assert {:ok, retry} = SQLite.merge(log_id, entries)
    assert retry.inserted == 0
    assert retry.present == 3
    assert count(public_store(log_id), "entries") == 3
    assert_clean(public_store(log_id))
  end

  test "§18.3 two replicas appending under different writer IDs converge in either sync order",
       ctx do
    writer_a = UUID.uuidv7()
    writer_b = UUID.uuidv7()
    chain_a = chain(ctx.log_id, writer_a, 3)
    chain_b = chain(ctx.log_id, writer_b, 2)
    stores = open_replicas(ctx, ~w(a1 b1 a2 b2))

    merge!(stores.a1, ctx.log_id, chain_a)
    merge!(stores.a2, ctx.log_id, chain_a)
    merge!(stores.b1, ctx.log_id, chain_b)
    merge!(stores.b2, ctx.log_id, chain_b)

    sync!(stores.a1, stores.b1, ctx.log_id, 100)
    sync!(stores.b1, stores.a1, ctx.log_id, 100)
    sync!(stores.b2, stores.a2, ctx.log_id, 100)
    sync!(stores.a2, stores.b2, ctx.log_id, 100)

    reference = byte_set(stores.a1, ctx.log_id)
    assert length(reference) == 5

    Enum.each(Map.values(stores), fn store ->
      assert byte_set(store, ctx.log_id) == reference

      assert LocalSQLite.frontier(store, ctx.log_id) ==
               LocalSQLite.frontier(stores.a1, ctx.log_id)

      assert_clean(store)
    end)
  end

  test "§18.4 three-way merge is associative for compatible replicas", ctx do
    low = chain(ctx.log_id, UUID.uuidv7(), 5)
    mid = chain(ctx.log_id, UUID.uuidv7(), 4)
    high = chain(ctx.log_id, UUID.uuidv7(), 2)
    state_a = Enum.take(low, 3)
    state_b = low ++ Enum.take(mid, 2)
    state_c = mid ++ high
    stores = open_replicas(ctx, ~w(left intermediate right))

    merge!(stores.left, ctx.log_id, state_a)
    merge!(stores.left, ctx.log_id, state_b)
    merge!(stores.left, ctx.log_id, state_c)

    merge!(stores.intermediate, ctx.log_id, state_b)
    merge!(stores.intermediate, ctx.log_id, state_c)
    merge!(stores.right, ctx.log_id, state_a)

    # Feed the right side from the intermediate replica's actual stored bytes.
    merge!(stores.right, ctx.log_id, stored_bytes(stores.intermediate, ctx.log_id))

    assert length(byte_set(stores.left, ctx.log_id)) == 11
    assert byte_set(stores.right, ctx.log_id) == byte_set(stores.left, ctx.log_id)

    assert LocalSQLite.frontier(stores.right, ctx.log_id) ==
             LocalSQLite.frontier(stores.left, ctx.log_id)

    Enum.each(Map.values(stores), &assert_clean/1)
  end

  test "§18.5 a shorter writer prefix extends to the longer prefix page by page", ctx do
    [long, short] = Map.values(open_replicas(ctx, ~w(long short)))
    entries = chain(ctx.log_id, UUID.uuidv7(), 7)
    merge!(long, ctx.log_id, entries)
    merge!(short, ctx.log_id, Enum.take(entries, 3))

    assert sync!(long, short, ctx.log_id, 2) == 2
    assert byte_set(short, ctx.log_id) == byte_set(long, ctx.log_id)
    assert {:ok, %{writers: [%{seq: 7}]}} = LocalSQLite.frontier(short, ctx.log_id)
    assert_clean(long)
    assert_clean(short)
  end

  test "§18.6 a missing sequence is rejected without partial insertion", %{log_id: log_id} do
    writer = UUID.uuidv7()
    initial = chain(log_id, writer, 2)
    assert {:ok, _} = SQLite.merge(log_id, initial)
    before = sql_snapshot(public_store(log_id))
    gapped = chain(log_id, writer, 2, start_seq: 4, prev: UUID.uuidv7())

    assert {:error, {:writer_gap, _}} = SQLite.merge(log_id, gapped)
    assert sql_snapshot(public_store(log_id)) == before
    assert_clean(public_store(log_id))
  end

  test "§18.7 a predecessor mismatch is reported as a writer fork", %{log_id: log_id} do
    writer = UUID.uuidv7()
    initial = chain(log_id, writer, 2)
    assert {:ok, _} = SQLite.merge(log_id, initial)
    [fork] = chain(log_id, writer, 1, start_seq: 3, prev: UUID.uuidv7())

    assert {:error, {:writer_fork, %{writer_id: ^writer, seq: 3}}} = SQLite.merge(log_id, [fork])
    assert count(public_store(log_id), "entries") == 2
    assert_clean(public_store(log_id))
  end

  test "§18.8 different entries at one writer coordinate are rejected", %{log_id: log_id} do
    writer = UUID.uuidv7()
    initial = chain(log_id, writer, 2)
    assert {:ok, _} = SQLite.merge(log_id, initial)
    original = canonical(Enum.at(initial, 1))

    rival =
      initial
      |> Enum.at(1)
      |> Map.merge(%{"entry_id" => UUID.uuidv7(), "body" => %{"rival" => true}})

    assert {:error, {:writer_fork, %{writer_id: ^writer, seq: 2}}} = SQLite.merge(log_id, [rival])
    assert stored_coordinate(public_store(log_id), writer, 2) == original
    assert_clean(public_store(log_id))
  end

  test "§18.9 reusing an entry UUID with different bytes is rejected", %{log_id: log_id} do
    writer = UUID.uuidv7()
    initial = chain(log_id, writer, 2)
    assert {:ok, _} = SQLite.merge(log_id, initial)

    collision = %{
      "version" => 1,
      "log_id" => log_id,
      "entry_id" => hd(initial)["entry_id"],
      "writer_id" => writer,
      "writer_seq" => 3,
      "prev_entry_id" => List.last(initial)["entry_id"],
      "created_at" => @created_at,
      "body" => %{"different" => true}
    }

    assert {:error, {:entry_id_collision, %{entry_id: _}}} = SQLite.merge(log_id, [collision])
    assert count(public_store(log_id), "entries") == 2
    assert_clean(public_store(log_id))
  end

  test "§18.10 a mixed-writer batch either commits completely or not at all", %{log_id: log_id} do
    writer_a = UUID.uuidv7()
    writer_b = UUID.uuidv7()
    [a1] = chain(log_id, writer_a, 1)
    [b1] = chain(log_id, writer_b, 1)
    assert {:ok, _} = SQLite.merge(log_id, [a1, b1])
    before = sql_snapshot(public_store(log_id))
    [a2] = chain(log_id, writer_a, 1, start_seq: 2, prev: a1["entry_id"])
    [b3] = chain(log_id, writer_b, 1, start_seq: 3, prev: UUID.uuidv7())

    assert {:error, {:writer_gap, _}} = SQLite.merge(log_id, [a2, b3])
    assert sql_snapshot(public_store(log_id)) == before
    assert_clean(public_store(log_id))
  end

  test "§18.11 local arrival order may differ while frontiers and canonical entries converge",
       ctx do
    [x, y] = Map.values(open_replicas(ctx, ~w(x y)))
    chain_a = chain(ctx.log_id, UUID.uuidv7(), 3)
    chain_b = chain(ctx.log_id, UUID.uuidv7(), 3)
    order_x = Enum.zip_with(chain_a, chain_b, &[&1, &2]) |> List.flatten()
    order_y = chain_b ++ chain_a

    Enum.each(order_x, &merge!(x, ctx.log_id, [&1]))
    merge!(y, ctx.log_id, chain_b)
    merge!(y, ctx.log_id, chain_a)

    ids_x = arrival_ids(x, ctx.log_id)
    ids_y = arrival_ids(y, ctx.log_id)
    assert ids_x == Enum.map(order_x, & &1["entry_id"])
    assert ids_y == Enum.map(order_y, & &1["entry_id"])
    refute ids_x == ids_y
    assert Enum.sort(ids_x) == Enum.sort(ids_y)
    assert byte_set(x, ctx.log_id) == byte_set(y, ctx.log_id)
    assert LocalSQLite.frontier(x, ctx.log_id) == LocalSQLite.frontier(y, ctx.log_id)
    assert_clean(x)
    assert_clean(y)
  end

  test "§18.12 timestamps do not affect merge results", ctx do
    times = [
      "2030-01-01T00:00:00Z",
      "1999-12-31T23:59:59Z",
      "2026-08-22T12:00:00Z",
      "1980-01-01T00:00:00Z",
      "2005-06-15T08:30:00Z"
    ]

    writer = UUID.uuidv7()
    entries = chain(ctx.log_id, writer, 5, times: times)
    by_time = entries |> Enum.sort_by(& &1["created_at"]) |> Enum.map(& &1["writer_seq"])
    assert by_time == [4, 2, 5, 3, 1]
    refute by_time == [1, 2, 3, 4, 5]
    [whole, paged] = Map.values(open_replicas(ctx, ~w(whole paged)))

    assert %{inserted: 5} = merge!(whole, ctx.log_id, entries)
    assert %{inserted: 2} = merge!(paged, ctx.log_id, Enum.take(entries, 2))
    assert %{inserted: 3} = merge!(paged, ctx.log_id, Enum.drop(entries, 2))

    assert {:ok, page} =
             LocalSQLite.read_writer(whole, ctx.log_id, writer, after_seq: 0, limit: 10)

    assert Enum.map(page.entries, & &1.writer_seq) == [1, 2, 3, 4, 5]
    assert byte_set(whole, ctx.log_id) == byte_set(paged, ctx.log_id)
    assert {:ok, %{writers: [%{seq: 5}]}} = LocalSQLite.frontier(whole, ctx.log_id)

    # §18.12 means created_at is advisory: it cannot choose position, order,
    # frontier, acceptance, or a conflict winner. Different timestamps still
    # produce different canonical entries and are not asserted equivalent.
    rival =
      List.last(entries)
      |> Map.merge(%{
        "entry_id" => UUID.uuidv7(),
        "created_at" => "2031-01-01T00:00:00Z",
        "body" => %{"pretender" => true}
      })

    assert {:error, {:writer_fork, %{seq: 5}}} =
             Engine.merge(LocalSQLite, whole, ctx.log_id, [canonical(rival)])

    assert_clean(whole)
    assert_clean(paged)
  end

  test "anti-vacuity: exactly §18.1 through §18.12 are registered once" do
    numbers =
      __MODULE__.__ex_unit__().tests
      |> Enum.map(&Atom.to_string(&1.name))
      |> Enum.flat_map(fn name ->
        case Regex.run(~r/^test §18\.(\d+) /, name) do
          [_, number] -> [String.to_integer(number)]
          nil -> []
        end
      end)

    assert Enum.sort(numbers) == Enum.to_list(1..12)
    assert length(numbers) == 12
  end

  test "the SQL audit reports deliberately inserted corruption", ctx do
    [store] = Map.values(open_replicas(ctx, ["corrupt"]))
    writer = UUID.uuidv7()
    entries = chain(ctx.log_id, writer, 2)
    merge!(store, ctx.log_id, entries)
    assert SQLAudit.audit(store) == []

    rogue_id = UUID.uuidv7()

    lying_bytes =
      chain(ctx.log_id, writer, 1, start_seq: 9, prev: UUID.uuidv7())
      |> hd()
      |> Map.put("entry_id", rogue_id)
      |> canonical()

    run!(
      store.conn,
      "INSERT INTO entries " <>
        "(entry_id, writer_id, writer_seq, prev_entry_id, created_at, canonical_json, received_at_ms) " <>
        "VALUES (?, ?, 4, ?, ?, ?, ?)",
      [rogue_id, writer, UUID.uuidv7(), @created_at, {:blob, lying_bytes}, 0]
    )

    violations = SQLAudit.audit(store)
    rules = Enum.map(violations, & &1.rule)
    assert "writer-count-max" in rules
    assert "writer-max-tip" in rules
    assert "predecessor-chain" in rules
    assert "projection-columns" in rules
    assert Enum.all?(violations, &(&1[:writer_id] == writer or &1[:coordinate] == {writer, 4}))
  end

  test "acknowledged public writes survive a server restart and the chain continues", %{
    log_id: log_id
  } do
    assert {:ok, first} = SQLite.append(log_id, "ignored", %{"n" => 1}, @created_at)
    assert {:ok, second} = SQLite.append(log_id, "ignored", %{"n" => 2}, @created_at)
    old_pid = public_server(log_id)
    monitor = Process.monitor(old_pid)
    GenServer.stop(old_pid)
    assert_receive {:DOWN, ^monitor, :process, ^old_pid, :normal}

    assert {:ok, %{writers: [%{writer_id: writer, seq: 2, entry_id: second_id}]}} =
             SQLite.frontier(log_id)

    assert writer == first.writer_id
    assert second_id == second.entry_id
    new_pid = public_server(log_id)
    refute new_pid == old_pid
    refute Process.alive?(old_pid)

    assert {:ok, third} = SQLite.append(log_id, "ignored", %{"n" => 3}, @created_at)
    assert third.writer_id == writer
    assert third.writer_seq == 3
    assert {:ok, page} = SQLite.read_writer(log_id, writer, after_seq: 0, limit: 10)
    assert Enum.map(page.entries, & &1.writer_seq) == [1, 2, 3]
    assert_clean(public_store(log_id))
  end

  defp open_replicas(ctx, names) do
    Map.new(names, fn name ->
      dir = Path.join(ctx.root, name)
      {:ok, store} = LocalSQLite.open(dir, ctx.log_id)
      :ok = LocalSQLite.create_log(store, ctx.log_id, %{format_version: 1})
      on_exit(fn -> LocalSQLite.close(store) end)
      {String.to_atom(name), store}
    end)
  end

  defp merge!(store, log_id, entries) do
    assert {:ok, result} =
             Engine.merge(LocalSQLite, store, log_id, Enum.map(entries, &canonical/1))

    result
  end

  defp sync!(source, destination, log_id, page_size) do
    {:ok, %{writers: source_tips}} = LocalSQLite.frontier(source, log_id)
    {:ok, %{writers: destination_tips}} = LocalSQLite.frontier(destination, log_id)
    destination_by_writer = Map.new(destination_tips, &{&1.writer_id, &1.seq})

    Enum.reduce(source_tips, 0, fn tip, pages ->
      after_seq = Map.get(destination_by_writer, tip.writer_id, 0)
      pages + sync_writer!(source, destination, log_id, tip, after_seq, page_size, 0)
    end)
  end

  defp sync_writer!(source, destination, log_id, tip, after_seq, limit, pages) do
    assert {:ok, page} =
             LocalSQLite.read_writer(source, log_id, tip.writer_id,
               after_seq: after_seq,
               through_seq: tip.seq,
               limit: limit
             )

    if page.entries == [] do
      pages
    else
      merge!(destination, log_id, Enum.map(page.entries, & &1.canonical_bytes))

      if page.next_after_seq do
        sync_writer!(source, destination, log_id, tip, page.next_after_seq, limit, pages + 1)
      else
        pages + 1
      end
    end
  end

  defp chain(log_id, writer_id, count, opts \\ []) do
    start_seq = Keyword.get(opts, :start_seq, 1)
    first_prev = Keyword.get(opts, :prev)
    times = Keyword.get(opts, :times)

    Enum.map_reduce(start_seq..(start_seq + count - 1), first_prev, fn seq, prev ->
      entry_id = UUID.uuidv7()
      created_at = if times, do: Enum.at(times, seq - start_seq), else: @created_at

      entry = %{
        "version" => 1,
        "log_id" => log_id,
        "entry_id" => entry_id,
        "writer_id" => writer_id,
        "writer_seq" => seq,
        "prev_entry_id" => prev,
        "created_at" => created_at,
        "body" => %{"seq" => seq}
      }

      {entry, entry_id}
    end)
    |> elem(0)
  end

  defp canonical(bytes) when is_binary(bytes), do: bytes
  defp canonical(entry), do: Jcs.canonicalize(entry)

  defp byte_set(store, log_id), do: store |> stored_bytes(log_id) |> Enum.sort()

  defp stored_bytes(store, log_id) do
    {:ok, page} = LocalSQLite.tail_local(store, log_id, after_arrival: 0, limit: 10_000)
    Enum.map(page.entries, & &1.canonical_bytes)
  end

  defp arrival_ids(store, log_id) do
    store
    |> stored_bytes(log_id)
    |> Enum.map(&Jason.decode!(&1)["entry_id"])
  end

  defp assert_clean(store), do: assert(SQLAudit.audit(store) == [])

  defp sql_snapshot(store) do
    %{
      counts:
        query!(
          store.conn,
          "SELECT writer_id, COUNT(*) FROM entries GROUP BY writer_id ORDER BY writer_id"
        ),
      tips:
        query!(
          store.conn,
          "SELECT writer_id, last_seq, last_entry_id FROM writer_tips ORDER BY writer_id"
        )
    }
  end

  defp stored_coordinate(store, writer, seq) do
    [[bytes]] =
      query!(
        store.conn,
        "SELECT canonical_json FROM entries WHERE writer_id = ? AND writer_seq = ?",
        [
          writer,
          seq
        ]
      )

    bytes
  end

  defp count(store, table) when table in ["entries", "writer_tips"] do
    [[count]] = query!(store.conn, "SELECT COUNT(*) FROM " <> table)
    count
  end

  defp public_store(log_id), do: public_server(log_id) |> :sys.get_state() |> Map.fetch!(:store)

  defp public_server(log_id) do
    [{pid, _}] = Registry.lookup(Commonplace.LogStore.SQLite.Registry, log_id)
    pid
  end

  defp stop_all_servers do
    if Process.whereis(Commonplace.LogStore.SQLite.Registry) do
      Registry.select(Commonplace.LogStore.SQLite.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
      |> Enum.each(fn log_id ->
        case Registry.lookup(Commonplace.LogStore.SQLite.Registry, log_id) do
          [{pid, _}] -> if Process.alive?(pid), do: GenServer.stop(pid)
          [] -> :ok
        end
      end)
    end
  end

  defp query!(conn, sql, params \\ []) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      {:ok, rows} = Sqlite3.fetch_all(conn, statement)
      rows
    after
      Sqlite3.release(conn, statement)
    end
  end

  defp run!(conn, sql, params) do
    {:ok, statement} = Sqlite3.prepare(conn, sql)

    try do
      :ok = Sqlite3.bind(statement, params)
      :done = Sqlite3.step(conn, statement)
      :ok
    after
      Sqlite3.release(conn, statement)
    end
  end
end
