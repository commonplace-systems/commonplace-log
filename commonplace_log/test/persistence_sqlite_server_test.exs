defmodule Commonplace.Log.Persistence.SQLiteServerTest do
  # async: false — the SQLite lane uses one application env key and one global
  # Registry, exactly as document_profile_test.exs does.
  use ExUnit.Case, async: false

  alias Commonplace.Log.{DocumentProfile, Frontier, UUID}
  alias Commonplace.Log.DocumentProfile.Lane.Sidecar, as: SidecarLane
  alias Commonplace.Log.Persistence.{CloudflareSidecar, SQLiteServer}
  alias Commonplace.Log.Test.{InMemoryPersistence, SidecarLoopback}
  alias Commonplace.LogStore.SQLite
  alias Commonplace.LogStore.SQLite.Server

  @created_at ~U[2026-09-03 04:00:00Z]

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "commonplace-sqlite-server-adapter-#{System.unique_integer([:positive])}"
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

  # L1 — RED AT BASE. Before this round `handle.adapter` was
  # `Commonplace.LogStore.SQLite`, whose `frontier/1` is arity 1, so this exact
  # call raised UndefinedFunctionError: frontier/2 is undefined.
  test "a SQLite-lane handle reaches the generic frontier value through handle.adapter", ctx do
    {:ok, handle} = seeded_handle(ctx.log_id)

    assert {:ok, %Frontier{tips: tips}} = Frontier.frontier_value(bound_log(handle))
    assert length(tips) == 1

    assert {:ok, %Frontier{}} = Server.frontier_value(handle.store)
    assert Frontier.frontier_value(bound_log(handle)) == Server.frontier_value(handle.store)
  end

  # L1 — the second generic helper, over the same handle.
  test "a SQLite-lane handle reads its own prefix through the generic read_through", ctx do
    {:ok, handle} = seeded_handle(ctx.log_id)
    {:ok, frontier} = Frontier.frontier_value(bound_log(handle))

    assert {:ok, entries} = Frontier.read_through(bound_log(handle), frontier, [])
    assert length(entries) == 2
    assert entries == elem(Server.read_through(handle.store, frontier, []), 1)
  end

  # L2 — CONTROL. The sidecar lane already published a Persistence module, so
  # this arm passes at the base commit and at this one. If it ever fails, the
  # generic helpers broke, not this adapter.
  test "a sidecar-lane handle reaches the same generic frontier value", _ctx do
    {:ok, base} = InMemoryPersistence.start_link()

    store =
      CloudflareSidecar.new("https://loopback.example",
        transport: SidecarLoopback,
        transport_options: {InMemoryPersistence, base}
      )

    log_id = UUID.uuidv7()
    {:ok, handle} = DocumentProfile.create_log(log_id, lane: {SidecarLane, store})
    {:ok, _result} = DocumentProfile.append(handle, %{"n" => 1}, created_at: @created_at)

    assert handle.adapter == CloudflareSidecar
    assert {:ok, %Frontier{tips: [_tip]}} = Frontier.frontier_value(bound_log(handle))
  end

  # L3 — read_set through the proxy against the server's own read path, both
  # polarities: a known tip resolves, an unknown tip is refused the same way.
  test "read_set through the proxy answers the server's own state, and refuses an unknown tip",
       ctx do
    {:ok, handle} = seeded_handle(ctx.log_id)
    {:ok, frontier} = Frontier.frontier_value(bound_log(handle))
    [tip] = frontier.tips

    query = %{writers: [], coordinates: [], entry_ids: [tip]}

    assert {:ok, read_set} = SQLiteServer.read_set(handle.store, ctx.log_id, query)
    assert Map.has_key?(read_set.entry_ids, tip)
    assert read_set.log_id == ctx.log_id
    assert read_set == elem(Server.read_set(handle.store, query), 1)

    unknown = Frontier.new(["018f1000-0000-7000-8000-000000000099"])

    assert Frontier.read_through(bound_log(handle), unknown, []) ==
             Server.read_through(handle.store, unknown, [])

    assert {:error, %Frontier.Error{reason: :unknown_tip}} =
             Frontier.read_through(bound_log(handle), unknown, [])
  end

  # L4 — the two paged reads, proxy against the server directly.
  test "tail_local and read_writer through the proxy equal the server's direct answers", ctx do
    {:ok, handle} = seeded_handle(ctx.log_id)

    assert {:ok, %{entries: tail, next_after_arrival: nil}} =
             SQLiteServer.tail_local(handle.store, ctx.log_id, after_arrival: 0, limit: 10)

    assert length(tail) == 2
    assert {:ok, %{entries: ^tail}} = Server.tail_local(handle.store, after_arrival: 0, limit: 10)

    assert {:ok, %{entries: page, next_after_seq: nil}} =
             SQLiteServer.read_writer(handle.store, ctx.log_id, handle.writer_id,
               after_seq: 0,
               limit: 10
             )

    assert length(page) == 2

    assert {:ok, %{entries: ^page}} =
             Server.read_writer(handle.store, handle.writer_id, after_seq: 0, limit: 10)
  end

  # The guard that makes the log binding real rather than assumed: the server
  # answers about its own log whatever it is asked, so the proxy must refuse.
  test "every read refuses a log_id the server does not own", ctx do
    {:ok, handle} = seeded_handle(ctx.log_id)
    other = UUID.uuidv7()
    query = %{writers: [], coordinates: [], entry_ids: []}

    assert {:error, :log_mismatch} = SQLiteServer.frontier(handle.store, other)
    assert {:error, :log_mismatch} = SQLiteServer.read_set(handle.store, other, query)
    assert {:error, :log_mismatch} = SQLiteServer.take_lease(handle.store, other)
    assert {:error, :log_mismatch} = SQLiteServer.create_log(handle.store, other, %{})

    assert {:error, :log_mismatch} =
             SQLiteServer.tail_local(handle.store, other, after_arrival: 0, limit: 1)

    assert {:error, :log_mismatch} =
             SQLiteServer.read_writer(handle.store, other, "writer", after_seq: 0, limit: 1)

    # and the same call for the owned log is not refused — the control that
    # stops this arm passing because everything is refused.
    assert {:ok, %{writers: [_writer]}} = SQLiteServer.frontier(handle.store, ctx.log_id)
  end

  # L7 — the field's only other consumer in this repo.
  test "the handle Inspect impl still renders, naming the new adapter", ctx do
    {:ok, handle} = seeded_handle(ctx.log_id)

    rendered = inspect(handle)
    assert rendered =~ "Commonplace.Log.DocumentProfile.Handle<"
    assert rendered =~ "adapter: Commonplace.Log.Persistence.SQLiteServer"
    assert rendered =~ ctx.log_id
  end

  defp seeded_handle(log_id) do
    {:ok, handle} = DocumentProfile.create_log(log_id, [])
    {:ok, _first} = DocumentProfile.append(handle, %{"n" => 1}, created_at: @created_at)
    {:ok, _second} = DocumentProfile.append(handle, %{"n" => 2}, created_at: @created_at)
    {:ok, handle}
  end

  defp bound_log(handle) do
    %{module: handle.adapter, store: handle.store, log_id: handle.log_id}
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
