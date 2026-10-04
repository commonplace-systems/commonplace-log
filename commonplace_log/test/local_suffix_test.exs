defmodule Commonplace.Log.LocalSuffixTest do
  @moduledoc """
  CHECKPOINT-SNAP-1 Phase B round 3, PROOF 3 (a gate): the DAG
  traversal-prefix proof for the backend-paged local suffix read.

  Over generated logs -- several local writers appending, several remote
  writers whose entries arrive by `merge/2` in interleaved batches, cuts taken
  at random arrival coordinates (including 0 and the current end) -- every
  verified suffix read after a cut F must be EXACTLY the tail `(F, E]`: none
  missed, none duplicated, nothing at or before F, ending at the captured E.
  The prefix at F must be down-closed in every writer chain (a DAG traversal
  prefix), unchanged since the cut was taken, and prefix ++ suffix must be the
  whole log through E.

  Wrong, foreign, stale and restored-incarnation frontiers are REFUSED, never
  answered as an empty suffix. Appends racing a paged read land after E and
  are returned by the next read. The red arms show the oracle itself goes red
  on each defect shape (off-by-one, prefix leak, skipped writer, short read).
  """
  use ExUnit.Case, async: false

  alias Commonplace.Log.{Engine, LocalFrontier, LocalSidecar, LocalSuffix}
  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.LogStore.SQLite

  @created_at "2026-10-04T00:00:00Z"
  @histories 200

  setup do
    root = Path.join(System.tmp_dir!(), "cn-local-suffix-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  # ── generation ─────────────────────────────────────────────────────────

  defp uuid, do: Commonplace.Log.UUID.uuidv7()

  defp new_store(dir, log_id) do
    File.mkdir_p!(dir)
    {:ok, store} = LocalSQLite.open(dir, log_id)
    :ok = LocalSQLite.create_log(store, log_id, %{format_version: 1})
    store
  end

  defp log_of(store), do: %{module: LocalSQLite, store: store, log_id: store.log_id}

  defp append!(store, writer, n) do
    {:ok, _} = Engine.append(LocalSQLite, store, store.log_id, writer, %{"n" => n}, @created_at)
  end

  defp all_rows(store) do
    {:ok, %{entries: rows, next_after_arrival: nil}} =
      LocalSQLite.tail_local(store, store.log_id, after_arrival: 0, limit: 1_000_000)

    rows
  end

  defp max_arrival(store), do: store |> all_rows() |> List.last() |> then(&if(&1, do: &1.arrival_seq, else: 0))

  defp writer_bytes(remote, writer) do
    {:ok, %{entries: rows, next_after_seq: nil}} =
      LocalSQLite.read_writer(remote, remote.log_id, writer, after_seq: 0, limit: 1_000_000)

    Enum.map(rows, & &1.canonical_bytes)
  end

  # One generated history. Returns the target store and the cuts taken, each
  # `{local_frontier, prefix_rows_at_cut}`.
  defp generate(root, seed) do
    :rand.seed(:exsss, {seed, seed * 7 + 1, seed * 13 + 5})
    log_id = uuid()
    target = new_store(Path.join(root, "t#{seed}"), log_id)
    locals = for _ <- 1..Enum.random(1..2), do: uuid()

    remotes =
      for i <- 1..Enum.random(0..3)//1 do
        writer = uuid()
        remote = new_store(Path.join(root, "r#{seed}-#{i}"), log_id)
        for n <- 1..Enum.random(3..12), do: append!(remote, writer, n)
        {writer, remote}
      end

    pending = Map.new(remotes, fn {w, r} -> {w, writer_bytes(r, w)} end)
    steps = Enum.random(12..30)

    {_pending, cuts} =
      Enum.reduce(1..steps, {pending, []}, fn step, {pending, cuts} ->
        cuts = if :rand.uniform(4) == 1, do: [cut(target) | cuts], else: cuts
        live = for {w, [_ | _]} <- pending, do: w

        if live != [] and :rand.uniform(2) == 1 do
          # merge the next 1..3 entries of 1 or 2 remote writers in ONE batch
          chosen = Enum.take_random(live, Enum.random(1..min(2, length(live))))

          {batch, pending} =
            Enum.reduce(chosen, {[], pending}, fn w, {batch, pending} ->
              {take, rest} = Enum.split(pending[w], Enum.random(1..3))
              {batch ++ take, Map.put(pending, w, rest)}
            end)

          {:ok, _} = Engine.merge(LocalSQLite, target, log_id, batch)
          {pending, cuts}
        else
          append!(target, Enum.random(locals), step)
          {pending, cuts}
        end
      end)

    cuts = [cut(target) | cuts]
    for {_w, r} <- remotes, do: LocalSQLite.close(r)
    {target, Enum.reverse(cuts)}
  end

  # A cut at a random existing arrival coordinate (or 0, or the end).
  defp cut(store) do
    rows = all_rows(store)
    arrivals = [0 | Enum.map(rows, & &1.arrival_seq)]
    at = Enum.random(arrivals)
    {:ok, f} = LocalSQLite.local_frontier(store, store.log_id, at)
    {f, Enum.filter(rows, &(&1.arrival_seq <= at))}
  end

  # ── the oracle ─────────────────────────────────────────────────────────

  # `result` must be exactly the tail of `rows_now` after F through E.
  def check_cut(rows_now, %LocalFrontier{} = f, prefix_at_cut, result) do
    through = result.through
    expected = Enum.filter(rows_now, &(&1.arrival_seq > f.arrival_seq and &1.arrival_seq <= through))
    prefix_now = Enum.filter(rows_now, &(&1.arrival_seq <= f.arrival_seq))
    got_ids = Enum.map(result.entries, &entry_id/1)
    whole = Enum.filter(rows_now, &(&1.arrival_seq <= through))

    cond do
      through != (rows_now |> List.last() |> then(&if(&1, do: &1.arrival_seq, else: 0))) ->
        {:error, :through_not_end}

      length(got_ids) != length(Enum.uniq(got_ids)) ->
        {:error, :duplicated}

      Enum.any?(result.entries, &(&1.arrival_seq <= f.arrival_seq)) ->
        {:error, :prefix_leak}

      result.entries != expected ->
        {:error, :not_exact_tail}

      prefix_now != prefix_at_cut ->
        {:error, :prefix_changed}

      prefix_now ++ result.entries != whole ->
        {:error, :not_a_partition}

      not down_closed?(prefix_now) ->
        {:error, :prefix_not_down_closed}

      true ->
        :ok
    end
  end

  defp entry_id(row), do: Jason.decode!(row.canonical_bytes)["entry_id"]

  # Every entry's writer predecessor is in the prefix (a DAG traversal prefix).
  defp down_closed?(rows) do
    entries = Enum.map(rows, &Jason.decode!(&1.canonical_bytes))
    ids = MapSet.new(entries, & &1["entry_id"])
    Enum.all?(entries, fn e -> e["prev_entry_id"] == nil or MapSet.member?(ids, e["prev_entry_id"]) end)
  end

  # ── PROOF 3 ────────────────────────────────────────────────────────────

  test "PROOF 3: every verified suffix after a cut is exactly the tail, over #{@histories} generated logs",
       %{root: root} do
    stats =
      Enum.reduce(1..@histories, %{cuts: 0, nonempty: 0, multiwriter: 0, pages: 0}, fn seed, stats ->
        {target, cuts} = generate(root, seed)
        rows_now = all_rows(target)
        writers = rows_now |> Enum.map(&Jason.decode!(&1.canonical_bytes)["writer_id"]) |> Enum.uniq()

        stats =
          Enum.reduce(cuts, stats, fn {f, prefix_at_cut}, stats ->
            page_size = Enum.random(1..5)
            assert {:ok, result} = LocalSuffix.read(log_of(target), f, page_size: page_size)
            assert :ok == check_cut(rows_now, f, prefix_at_cut, result), "seed #{seed} cut #{f.arrival_seq}"
            # the wire form round-trips and still verifies
            assert {:ok, ^f} = LocalFrontier.decode(LocalFrontier.encode(f))

            %{
              stats
              | cuts: stats.cuts + 1,
                nonempty: stats.nonempty + if(result.entries != [], do: 1, else: 0),
                pages: stats.pages + result.pages
            }
          end)

        LocalSQLite.close(target)
        %{stats | multiwriter: stats.multiwriter + if(length(writers) > 1, do: 1, else: 0)}
      end)

    # anti-vacuity: the corpus really exercised multi-page, multi-writer tails
    assert stats.cuts >= @histories
    assert stats.nonempty >= div(stats.cuts, 2)
    assert stats.multiwriter >= div(@histories, 2)
    assert stats.pages > stats.cuts
    IO.puts("PROOF3 histories=#{@histories} cuts=#{stats.cuts} nonempty=#{stats.nonempty} multiwriter=#{stats.multiwriter} pages=#{stats.pages}")
  end

  test "red arms: the oracle refuses off-by-one, prefix leak, skipped writer and short reads",
       %{root: root} do
    fired =
      Enum.reduce(1..60, %{off_by_one: 0, prefix_leak: 0, skipped_writer: 0, short: 0}, fn seed, fired ->
        {target, cuts} = generate(root, 10_000 + seed)
        rows_now = all_rows(target)

        fired =
          Enum.reduce(cuts, fired, fn {f, prefix}, fired ->
            {:ok, good} = LocalSuffix.read(log_of(target), f)
            assert :ok == check_cut(rows_now, f, prefix, good)

            mutants = %{
              off_by_one: Enum.filter(rows_now, &(&1.arrival_seq >= f.arrival_seq and &1.arrival_seq > 0)),
              prefix_leak: rows_now,
              skipped_writer:
                case good.entries do
                  [first | _] ->
                    w = Jason.decode!(first.canonical_bytes)["writer_id"]
                    Enum.reject(good.entries, &(Jason.decode!(&1.canonical_bytes)["writer_id"] == w))

                  [] ->
                    []
                end,
              short: Enum.drop(good.entries, -1)
            }

            Enum.reduce(mutants, fired, fn {arm, entries}, fired ->
              if entries == good.entries do
                fired
              else
                assert {:error, _} = check_cut(rows_now, f, prefix, %{good | entries: entries}), "#{arm}"
                # the production-side range check refuses the shapes it can see alone
                if arm in [:off_by_one, :prefix_leak, :short] do
                  assert {:error, {:local_suffix_inconsistent, _}} =
                           LocalSuffix.check_range(entries, f.arrival_seq, good.through)
                end

                Map.update!(fired, arm, &(&1 + 1))
              end
            end)
          end)

        LocalSQLite.close(target)
        fired
      end)

    for {arm, n} <- fired, do: assert(n > 0, "red arm #{arm} never exercised")
  end

  # ── refusals: wrong / foreign / stale / restored F ──────────────────────

  test "a wrong, foreign or stale F is refused, never read as an empty suffix", %{root: root} do
    {target, _} = generate(root, 77)
    rows = all_rows(target)
    assert length(rows) > 6
    mid = Enum.at(rows, div(length(rows), 2)).arrival_seq
    {:ok, f} = LocalSQLite.local_frontier(target, target.log_id, mid)
    log = log_of(target)
    assert {:ok, _} = LocalSuffix.read(log, f)

    # a LATER row: the tampered value stays well-formed, so only the log can refuse it
    other = List.last(rows).arrival_seq
    assert other != mid
    refused = fn f -> LocalSuffix.read(log, f) end

    assert {:error, {:local_frontier_refused, :entry_mismatch}} = refused.(%{f | arrival_seq: other} |> fix_writers(other))
    assert {:error, {:local_frontier_refused, :entry_mismatch}} = refused.(%{f | entry_digest: String.duplicate("0", 64)})
    assert {:error, {:local_frontier_refused, :beyond_end}} = refused.(%{f | arrival_seq: max_arrival(target) + 1})
    [w | ws] = f.writers
    assert {:error, {:local_frontier_refused, :writer_prefix_mismatch}} = refused.(%{f | writers: [%{w | seq: w.seq + 1} | ws]})

    if ws != [] do
      assert {:error, {:local_frontier_refused, :writer_prefix_mismatch}} = refused.(%{f | writers: [w]})
    end

    assert {:error, {:local_frontier_refused, :incarnation_mismatch}} = refused.(%{f | incarnation: String.duplicate("a", 64)})
    assert {:error, {:local_frontier_refused, :malformed}} = refused.(%{f | writers: :nope})

    # foreign: another log's frontier
    foreign_store = new_store(Path.join(root, "foreign"), uuid())
    append!(foreign_store, uuid(), 1)
    {:ok, foreign} = LocalSQLite.local_frontier(foreign_store, foreign_store.log_id, 1)
    assert {:error, {:local_frontier_refused, :log_mismatch}} = refused.(foreign)

    # stale: the same log id re-created elsewhere (new incarnation), same entries merged in
    copy = new_store(Path.join(root, "recreated"), target.log_id)
    {:ok, _} = Engine.merge(LocalSQLite, copy, target.log_id, Enum.map(rows, & &1.canonical_bytes) |> per_writer_order())
    assert {:error, {:local_frontier_refused, :incarnation_mismatch}} = LocalSuffix.read(log_of(copy), f)
  end

  # A stale frontier from before a restore: the restored copy holds the same
  # entries but is a new incarnation.
  test "a restored copy is a new incarnation: the source's F is refused", %{root: root} do
    log_id = uuid()
    source = new_store(Path.join(root, "src"), log_id)
    writer = uuid()
    for n <- 1..8, do: append!(source, writer, n)
    {:ok, f} = LocalSQLite.local_frontier(source, log_id, 5)
    rows = all_rows(source)
    last = Jason.decode!(List.last(rows).canonical_bytes)

    spec = %{
      writer_id: writer,
      writer_seq: 8,
      tip_entry_id: last["entry_id"],
      frontier_digest: :crypto.hash(:sha256, "x"),
      entry_count: 8
    }

    dir = Path.join(root, "restored")
    File.mkdir_p!(dir)
    {:ok, restored} = LocalSQLite.open(dir, log_id)
    assert :ok = LocalSQLite.prepare_restore(restored, log_id, spec)
    {:ok, _} = Engine.merge(LocalSQLite, restored, log_id, Enum.map(rows, & &1.canonical_bytes))
    assert :ok = LocalSQLite.complete_restore(restored, log_id, spec)
    assert all_rows(restored) |> Enum.map(& &1.canonical_bytes) == Enum.map(rows, & &1.canonical_bytes)

    assert {:error, {:local_frontier_refused, :incarnation_mismatch}} = LocalSuffix.read(log_of(restored), f)
    {:ok, own} = LocalSQLite.local_frontier(restored, log_id, 5)
    assert own.incarnation != f.incarnation
    assert {:ok, %{entries: tail}} = LocalSuffix.read(log_of(restored), own)
    assert length(tail) == 3
  end

  # ── appends racing the read ────────────────────────────────────────────

  describe "through the serialized log owner" do
    setup %{root: root} do
      previous = Application.get_env(:commonplace_log, SQLite)
      Application.put_env(:commonplace_log, SQLite, data_dir: Path.join(root, "owner"))

      on_exit(fn ->
        Registry.select(Commonplace.LogStore.SQLite.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
        |> Enum.each(&DynamicSupervisor.terminate_child(Commonplace.LogStore.SQLite.DynamicSupervisor, &1))

        if previous,
          do: Application.put_env(:commonplace_log, SQLite, previous),
          else: Application.delete_env(:commonplace_log, SQLite)
      end)

      :ok
    end

    test "appends racing paged reads land after E and are returned by the next read" do
      log_id = uuid()
      assert :ok = SQLite.create_log(log_id)
      for n <- 1..40, do: {:ok, _} = SQLite.append(log_id, nil, %{"n" => n}, @created_at)
      {:ok, f} = SQLite.local_frontier(log_id, 15)

      appender =
        Task.async(fn ->
          for n <- 41..240, do: {:ok, _} = SQLite.append(log_id, nil, %{"n" => n}, @created_at)
          :done
        end)

      reads =
        Stream.repeatedly(fn ->
          {:ok, r} = SQLite.read_local_suffix(log_id, f, page_size: 3)
          r
        end)
        |> Enum.take(25)

      :done = Task.await(appender, 60_000)
      {:ok, %{entries: all, next_after_arrival: nil}} = SQLite.tail_local(log_id, after_arrival: 0, limit: 1_000_000)

      throughs = Enum.map(reads, & &1.through)
      assert throughs == Enum.sort(throughs)

      for r <- reads do
        expected = Enum.filter(all, &(&1.arrival_seq > 15 and &1.arrival_seq <= r.through))
        assert r.entries == expected
      end

      assert Enum.uniq(throughs) |> length() > 1, "the read never raced an append"

      # the next read from the last E returns exactly the rest
      last = List.last(reads)
      {:ok, f2} = SQLite.local_frontier(log_id, last.through)
      {:ok, rest} = SQLite.read_local_suffix(log_id, f2)
      assert last.entries ++ rest.entries == Enum.filter(all, &(&1.arrival_seq > 15))
      assert rest.through == List.last(all).arrival_seq
    end

    test "restore_log clears a sidecar left at the target path" do
      source = uuid()
      assert :ok = SQLite.create_log(source)
      for n <- 1..3, do: {:ok, _} = SQLite.append(source, nil, %{"n" => n}, @created_at)
      {:ok, frontier} = SQLite.frontier_value(source)
      {:ok, entries} = SQLite.read_through(source, frontier, [])
      {:ok, sidecar} = SQLite.sidecar_path(source)
      dir = Path.dirname(sidecar)

      target = Jason.decode!(hd(entries))["log_id"]
      assert target == source
      # a different target id (restore into a fresh log of the same id needs the source gone)
      Registry.select(Commonplace.LogStore.SQLite.Registry, [{{:_, :"$1", :_}, [], [:"$1"]}])
      |> Enum.each(&DynamicSupervisor.terminate_child(Commonplace.LogStore.SQLite.DynamicSupervisor, &1))

      for ext <- [".sqlite3", ".sqlite3-wal", ".sqlite3-shm", ".writer", ".lock.sqlite3"],
          do: File.rm(Path.join(dir, source <> ext))

      stale = LocalSidecar.path(dir, source)
      :ok = LocalSidecar.write(stale, "stale checkpoint")
      assert {:ok, "stale checkpoint"} = LocalSidecar.read(stale, 1024)

      assert {:ok, _} = SQLite.restore_log(source, entries, SQLite.restore_request(source, frontier))
      assert {:error, :missing} = LocalSidecar.read(stale, 1024)
    end
  end

  # ── sidecar file discipline ────────────────────────────────────────────

  test "sidecar: mode 600, atomic replace, bounded read, insecure mode refused", %{root: root} do
    path = LocalSidecar.path(root, uuid())
    assert {:error, :missing} = LocalSidecar.read(path, 10)
    assert :ok = LocalSidecar.write(path, "one")
    assert {:ok, %File.Stat{mode: mode}} = File.stat(path)
    assert Bitwise.band(mode, 0o777) == 0o600
    assert :ok = LocalSidecar.write(path, "two")
    assert {:ok, "two"} = LocalSidecar.read(path, 10)
    assert {:error, :too_large} = LocalSidecar.read(path, 2)
    assert [] = Path.wildcard(path <> ".tmp-*")
    File.chmod!(path, 0o644)
    assert {:error, :insecure_mode} = LocalSidecar.read(path, 10)
    assert :ok = LocalSidecar.clear(path)
    assert :ok = LocalSidecar.clear(path)
    assert {:error, :missing} = LocalSidecar.read(path, 10)
  end

  test "an adapter without the optional callbacks is unsupported, not empty" do
    log = %{module: Commonplace.Log.Test.InMemoryPersistence, store: nil, log_id: uuid()}
    f = %LocalFrontier{log_id: log.log_id, incarnation: String.duplicate("a", 64), arrival_seq: 0, entry_id: nil, entry_digest: nil, writers: []}
    assert {:error, :local_suffix_unsupported} = LocalSuffix.read(log, f)
    assert {:error, :local_suffix_unsupported} = LocalSuffix.local_frontier(log, 0)
  end

  # helpers for the refusal test

  defp fix_writers(f, _other), do: f

  # merge needs each writer's entries in sequence order; arrival order already is.
  defp per_writer_order(bytes), do: bytes
end
