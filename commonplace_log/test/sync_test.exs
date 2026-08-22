defmodule Commonplace.Log.SyncTest do
  use ExUnit.Case, async: false

  alias Commonplace.Log.{Engine, Jcs, Sync, UUID}
  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.Log.Test.SQLAudit

  @created_at "2026-08-22T12:34:56Z"

  defmodule AdvancingReplica do
    @moduledoc false

    def frontier(%{control: control, extra: extra} = state, log_id) do
      result = Sync.PersistenceReplica.frontier(state.replica, log_id)

      if Agent.get_and_update(control, fn first? -> {first?, false} end) do
        {:ok, _} = Sync.PersistenceReplica.merge(state.replica, log_id, extra)
      end

      result
    end

    def read_writer(state, log_id, writer_id, opts) do
      Sync.PersistenceReplica.read_writer(state.replica, log_id, writer_id, opts)
    end

    def merge(state, log_id, entries) do
      Sync.PersistenceReplica.merge(state.replica, log_id, entries)
    end
  end

  defmodule DeadlineReplica do
    @moduledoc false

    def frontier(state, log_id) do
      Sync.PersistenceReplica.frontier(state.replica, log_id)
    end

    def read_writer(state, log_id, writer_id, opts) do
      Sync.PersistenceReplica.read_writer(state.replica, log_id, writer_id, opts)
    end

    def merge(state, log_id, entries) do
      result = Sync.PersistenceReplica.merge(state.replica, log_id, entries)
      Process.put(:sync_test_now, Process.get(:sync_test_now) + 1)
      result
    end
  end

  setup do
    root =
      Path.join(System.tmp_dir!(), "commonplace-sync-#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    %{root: root, log_id: UUID.uuidv7(), stores: []}
  end

  test "§18.3 converges through the Sync engine in either invocation order", ctx do
    writer_a = UUID.uuidv7()
    writer_b = UUID.uuidv7()
    entries_a = chain(ctx.log_id, writer_a, 4)
    entries_b = chain(ctx.log_id, writer_b, 3)
    stores = open_replicas(ctx, ~w(left_1 right_1 left_2 right_2))

    merge!(stores.left_1, ctx.log_id, entries_a)
    merge!(stores.right_1, ctx.log_id, entries_b)
    merge!(stores.left_2, ctx.log_id, entries_a)
    merge!(stores.right_2, ctx.log_id, entries_b)

    assert {:ok, %{outcome: :converged}} =
             Sync.sync(replica(stores.left_1), replica(stores.right_1), ctx.log_id, page_size: 2)

    assert {:ok, %{outcome: :converged}} =
             Sync.sync(replica(stores.right_2), replica(stores.left_2), ctx.log_id, page_size: 2)

    reference = byte_set(stores.left_1, ctx.log_id)
    assert length(reference) == 7

    Enum.each(Map.values(stores), fn store ->
      assert byte_set(store, ctx.log_id) == reference
      assert_clean(store)
    end)
  end

  test "page sizes 1, 2, and 7 cross different paging boundaries without changing results", ctx do
    writer = UUID.uuidv7()
    entries = chain(ctx.log_id, writer, 13)

    observations =
      Map.new([1, 2, 7], fn page_size ->
        stores = open_replicas(ctx, ["page_#{page_size}_local", "page_#{page_size}_remote"])
        local = stores[String.to_atom("page_#{page_size}_local")]
        remote = stores[String.to_atom("page_#{page_size}_remote")]
        merge!(local, ctx.log_id, Enum.take(entries, 2))
        merge!(remote, ctx.log_id, entries)

        assert {:ok, report} =
                 Sync.sync(replica(local), replica(remote), ctx.log_id, page_size: page_size)

        assert report.outcome == :converged
        assert byte_set(local, ctx.log_id) == byte_set(remote, ctx.log_id)
        assert_clean(local)
        assert_clean(remote)
        {page_size, report.pages}
      end)

    assert observations == %{1 => 11, 2 => 6, 7 => 2}
    assert observations |> Map.values() |> Enum.uniq() |> length() == 3
  end

  test "an expired deadline leaves a valid partial prefix and reports partial progress", ctx do
    [local, remote] = ctx |> open_replicas(~w(deadline_local deadline_remote)) |> Map.values()
    entries = chain(ctx.log_id, UUID.uuidv7(), 8)
    merge!(remote, ctx.log_id, entries)

    Process.put(:sync_test_now, 0)

    clock = fn -> Process.get(:sync_test_now) end

    deadline_local = %{
      module: DeadlineReplica,
      store: %{replica: replica(local).store}
    }

    assert {:ok, report} =
             Sync.sync(deadline_local, replica(remote), ctx.log_id,
               page_size: 2,
               deadline: 1,
               clock: clock
             )

    assert report.outcome == :deadline
    assert report.progress?
    refute report.converged?
    assert report.inserted == 2
    assert length(byte_set(local, ctx.log_id)) == 2
    assert_clean(local)
    assert_clean(remote)
  end

  test "a fork is detailed and isolated while a clean writer converges in the same pass", ctx do
    [local, remote] = ctx |> open_replicas(~w(fork_local fork_remote)) |> Map.values()
    forked_writer = UUID.uuidv7()
    clean_writer = UUID.uuidv7()
    common = chain(ctx.log_id, forked_writer, 2)
    local_branch = continue_chain(ctx.log_id, forked_writer, common, 1, "local")
    remote_branch = continue_chain(ctx.log_id, forked_writer, common, 1, "remote")
    clean = chain(ctx.log_id, clean_writer, 5)

    merge!(local, ctx.log_id, common ++ local_branch ++ Enum.take(clean, 1))
    merge!(remote, ctx.log_id, common ++ remote_branch ++ clean)

    assert {:ok, report} =
             Sync.pull(replica(local), replica(remote), ctx.log_id, page_size: 2)

    local_tip = tip!(local, ctx.log_id, forked_writer)
    remote_tip = tip!(remote, ctx.log_id, forked_writer)

    assert report.outcome == :forks
    refute report.converged?

    assert report.forks == [
             %{writer_id: forked_writer, local_tip: local_tip, remote_tip: remote_tip}
           ]

    assert tip!(local, ctx.log_id, clean_writer) == tip!(remote, ctx.log_id, clean_writer)
    assert tip!(local, ctx.log_id, clean_writer).seq == 5
    assert_clean(local)
    assert_clean(remote)
  end

  test "an entry appended after the first frontier snapshot requires another pass", ctx do
    [local, remote] = ctx |> open_replicas(~w(advance_local advance_remote)) |> Map.values()
    writer = UUID.uuidv7()
    initial = chain(ctx.log_id, writer, 3)
    extra = continue_chain(ctx.log_id, writer, initial, 1, "advanced")
    merge!(remote, ctx.log_id, initial)
    {:ok, control} = Agent.start_link(fn -> true end)

    advancing = %{
      module: AdvancingReplica,
      store: %{replica: replica(remote).store, control: control, extra: canonical(extra)}
    }

    assert {:ok, report} =
             Sync.sync(replica(local), advancing, ctx.log_id, page_size: 10)

    assert report.outcome == :converged
    assert report.passes == 2
    assert report.pages == 2
    assert byte_set(local, ctx.log_id) == byte_set(remote, ctx.log_id)
    assert tip!(local, ctx.log_id, writer).seq == 4
    assert_clean(local)
    assert_clean(remote)
  end

  test "a second synchronization with no new entries inserts nothing", ctx do
    [local, remote] = ctx |> open_replicas(~w(idempotent_local idempotent_remote)) |> Map.values()
    merge!(remote, ctx.log_id, chain(ctx.log_id, UUID.uuidv7(), 5))

    assert {:ok, first} = Sync.sync(replica(local), replica(remote), ctx.log_id, page_size: 2)
    assert first.inserted == 5

    before = byte_set(local, ctx.log_id)
    assert {:ok, second} = Sync.sync(replica(local), replica(remote), ctx.log_id, page_size: 2)
    assert second.outcome == :converged
    assert second.inserted == 0
    assert second.pages == 0
    assert byte_set(local, ctx.log_id) == before
    assert_clean(local)
    assert_clean(remote)
  end

  defp replica(store), do: Sync.persistence_replica(LocalSQLite, store)

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
    assert {:ok, result} = Engine.merge(LocalSQLite, store, log_id, canonical(entries))
    result
  end

  defp chain(log_id, writer_id, count) do
    build_chain(log_id, writer_id, 1, nil, count, "initial")
  end

  defp continue_chain(log_id, writer_id, prior, count, label) do
    last = List.last(prior)
    build_chain(log_id, writer_id, last["writer_seq"] + 1, last["entry_id"], count, label)
  end

  defp build_chain(log_id, writer_id, start_seq, first_prev, count, label) do
    Enum.map_reduce(start_seq..(start_seq + count - 1), first_prev, fn seq, prev ->
      entry_id = UUID.uuidv7()

      entry = %{
        "version" => 1,
        "log_id" => log_id,
        "entry_id" => entry_id,
        "writer_id" => writer_id,
        "writer_seq" => seq,
        "prev_entry_id" => prev,
        "created_at" => @created_at,
        "body" => %{"label" => label, "seq" => seq}
      }

      {entry, entry_id}
    end)
    |> elem(0)
  end

  defp canonical(entries), do: Enum.map(entries, &Jcs.canonicalize/1)

  defp byte_set(store, log_id) do
    {:ok, page} = LocalSQLite.tail_local(store, log_id, after_arrival: 0, limit: 10_000)
    page.entries |> Enum.map(& &1.canonical_bytes) |> Enum.sort()
  end

  defp tip!(store, log_id, writer_id) do
    {:ok, %{writers: writers}} = LocalSQLite.frontier(store, log_id)
    Enum.find(writers, &(&1.writer_id == writer_id))
  end

  defp assert_clean(store), do: assert(SQLAudit.audit(store) == [])
end
