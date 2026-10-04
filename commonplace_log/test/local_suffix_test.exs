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
  alias Commonplace.Log.LocalSuffixTest.PageSource
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

  # Every row, in the read_local_page shape (with the coordinate columns).
  defp all_rows(store) do
    {:ok, %{entries: rows, next_after_arrival: nil}} =
      LocalSQLite.read_local_page(store, store.log_id, 0, 1_000_000_000, 1_000_000)

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
      Enum.reduce(1..60, %{off_by_one: 0, prefix_leak: 0, skipped_writer: 0, short: 0, mid_skip: 0, dup: 0}, fn seed, fired ->
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
              short: Enum.drop(good.entries, -1),
              # F=4, E=8, pages 5,6,8: range-check-clean, still a skip
              mid_skip:
                (if length(good.entries) >= 3,
                   do: List.delete_at(good.entries, div(length(good.entries), 2)),
                   else: good.entries),
              dup:
                case good.entries do
                  [a, b | rest] -> [a, a, b | rest] |> Enum.drop(-1)
                  _ -> good.entries
                end
            }

            Enum.reduce(mutants, fired, fn {arm, entries}, fired ->
              if entries == good.entries do
                fired
              else
                assert {:error, _} = check_cut(rows_now, f, prefix, %{good | entries: entries}), "#{arm}"
                # the PRODUCTION checks (range + per-writer runs against the
                # writers the log captured at E) refuse every shape
                {:ok, %{writers: at_end}} = LocalSQLite.open_local_suffix(target, target.log_id, f)

                assert match?({:error, {:local_suffix_inconsistent, _}}, LocalSuffix.check_range(entries, f.arrival_seq, good.through)) or
                         match?({:error, {:local_suffix_inconsistent, _}}, LocalSuffix.check_writers(entries, f.writers, at_end)),
                       "production checks accepted #{arm}"

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

    assert {:error, {:local_frontier_refused, :entry_mismatch}} = refused.(%{f | arrival_seq: other})
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
    {:ok, _} = Engine.merge(LocalSQLite, copy, target.log_id, Enum.map(rows, & &1.canonical_bytes))
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
        assert Enum.map(r.entries, &Map.take(&1, [:canonical_bytes, :arrival_seq, :operation_id])) == expected
      end

      # (whether these reads actually interleaved with appends is scheduling;
      # the deterministic interleave is the next test)

      # the next read from the last E returns exactly the rest
      last = List.last(reads)
      {:ok, f2} = SQLite.local_frontier(log_id, last.through)
      {:ok, rest} = SQLite.read_local_suffix(log_id, f2)
      assert Enum.map(last.entries ++ rest.entries, &Map.take(&1, [:canonical_bytes, :arrival_seq, :operation_id])) ==
               Enum.filter(all, &(&1.arrival_seq > 15))
      assert rest.through == List.last(all).arrival_seq
    end

    test "appends landing BETWEEN pages (deterministic) are not in the result and come next" do
      log_id = uuid()
      assert :ok = SQLite.create_log(log_id)
      for n <- 1..30, do: {:ok, _} = SQLite.append(log_id, nil, %{"n" => n}, @created_at)
      {:ok, f} = SQLite.local_frontier(log_id, 10)
      [{server, _}] = Registry.lookup(Commonplace.LogStore.SQLite.Registry, log_id)
      inner = %{module: Commonplace.Log.Persistence.SQLiteServer, store: server, log_id: log_id}
      log = %{module: PageSource, store: {inner, :append_between_pages, self()}, log_id: log_id}

      assert {:ok, r} = LocalSuffix.read(log, f, page_size: 4)
      assert r.through == 30 and r.pages == 5
      {:ok, %{entries: all, next_after_arrival: nil}} = SQLite.tail_local(log_id, after_arrival: 0, limit: 1_000_000)
      assert length(all) == 34, "an append did not land between pages"
      assert Enum.map(r.entries, &Map.take(&1, [:canonical_bytes, :arrival_seq, :operation_id])) ==
               Enum.filter(all, &(&1.arrival_seq in 11..30))
      {:ok, f2} = SQLite.local_frontier(log_id, r.through)
      {:ok, rest} = SQLite.read_local_suffix(log_id, f2)
      assert Enum.map(rest.entries, &Map.take(&1, [:canonical_bytes, :arrival_seq, :operation_id])) ==
               Enum.filter(all, &(&1.arrival_seq > 30))
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

  # ── I1: production-path red arm (a page source that drops / repeats a row) ─

  test "a page source that drops, repeats or leaks a row is refused by LocalSuffix.read", %{root: root} do
    {target, _} = generate(root, 4242)
    rows = all_rows(target)
    mid = Enum.at(rows, 3).arrival_seq
    {:ok, f} = LocalSQLite.local_frontier(target, target.log_id, mid)
    inner = log_of(target)
    assert {:ok, good} = LocalSuffix.read(inner, f, page_size: 2)
    assert length(good.entries) >= 4

    for mode <- [:drop_one, :repeat_one, :leak_prefix] do
      log = %{module: PageSource, store: {inner, mode, nil}, log_id: target.log_id}
      assert {:error, {:local_suffix_inconsistent, _}} = LocalSuffix.read(log, f, page_size: 2), "#{mode}"
    end

    # control: the pass-through wrapper itself is accepted
    assert {:ok, ^good} =
             LocalSuffix.read(%{module: PageSource, store: {inner, :pass, nil}, log_id: target.log_id}, f, page_size: 2)
  end

  test "a mid-range skip with a clean range is still refused (F=4, E=8, pages 5,6,8)", %{root: root} do
    store = new_store(Path.join(root, "skip"), uuid())
    w = uuid()
    for n <- 1..8, do: append!(store, w, n)
    {:ok, f} = LocalSQLite.local_frontier(store, store.log_id, 4)
    {:ok, %{through: 8, writers: at_end}} = LocalSQLite.open_local_suffix(store, store.log_id, f)
    rows = all_rows(store) |> Enum.filter(&(&1.arrival_seq in [5, 6, 8]))
    assert :ok == LocalSuffix.check_range(rows, 4, 8)
    assert {:error, {:local_suffix_inconsistent, :writer_run}} = LocalSuffix.check_writers(rows, f.writers, at_end)
  end

  test "page rows carry coordinate columns equal to their canonical entry's fields", %{root: root} do
    {target, _} = generate(root, 515)

    for row <- all_rows(target) do
      e = Jason.decode!(row.canonical_bytes)
      assert {row.writer_id, row.writer_seq, row.entry_id} == {e["writer_id"], e["writer_seq"], e["entry_id"]}
    end

    # and a row without them is refused, not decoded
    [row | _] = all_rows(target)
    assert {:error, {:local_suffix_inconsistent, :unreadable_row}} =
             LocalSuffix.check_writers([Map.delete(row, :writer_id)], [], [])
  end

  test "verify/2 pages nothing and its suffix_count equals the paged count, over generated logs", %{root: root} do
    checked =
      Enum.reduce(1..40, 0, fn seed, checked ->
        {target, cuts} = generate(root, 20_000 + seed)
        log = log_of(target)

        n =
          Enum.reduce(cuts, 0, fn {f, prefix}, n ->
            # a page source that refuses every page proves verify reads none
            no_pages = %{module: PageSource, store: {log, :refuse_pages, nil}, log_id: target.log_id}
            assert {:ok, v} = LocalSuffix.verify(no_pages, f)
            assert v.applied == length(prefix)
            assert {:ok, r} = LocalSuffix.read_verified(log, v)
            assert v.suffix_count == length(r.entries)
            assert {:ok, ^r} = LocalSuffix.read(log, f)
            n + 1
          end)

        LocalSQLite.close(target)
        checked + n
      end)

    assert checked >= 40
  end

  test "verify/2 refuses what read/3 refuses", %{root: root} do
    {target, _} = generate(root, 77)
    {:ok, f} = LocalSQLite.local_frontier(target, target.log_id, 3)
    assert {:error, {:local_frontier_refused, :incarnation_mismatch}} =
             LocalSuffix.verify(log_of(target), %{f | incarnation: String.duplicate("a", 64)})
  end

  # ── I2: the per-writer probe is planner-proof ──────────────────────────────

  # Measured: with 1 or 2 writers (a Document log is single-writer) ANALYZE
  # flips the un-pinned query to a rowid range scan of the prefix; with 4 it
  # does not. All three shapes are asserted.
  test "after ANALYZE on 1-, 2- and 4-writer logs the per-writer probe still uses entries_by_writer",
       %{root: root} do
    for nwriters <- [1, 2, 4] do
      store = new_store(Path.join(root, "plan-#{nwriters}"), uuid())
      writers = for _ <- 1..nwriters, do: uuid()
      for n <- 1..div(600, nwriters), w <- writers, do: append!(store, w, n)
      :ok = Exqlite.Sqlite3.execute(store.conn, "ANALYZE")

      for f <- [10, 300, 590] do
        plan = explain(store.conn, LocalSQLite.writer_at_sql(), [hd(writers), f])
        assert uses_writer_index?(plan), "#{nwriters} writers, F=#{f}: #{inspect(plan)}"
      end

      # control: the detector goes red on a prefix scan
      refute uses_writer_index?(explain(store.conn, "SELECT entry_id FROM entries WHERE arrival_seq <= ?", [590]))
      # and the probe still answers correctly
      {:ok, f} = LocalSQLite.local_frontier(store, store.log_id, 590)
      assert Enum.map(f.writers, & &1.seq) |> Enum.sum() == 590
      LocalSQLite.close(store)
    end
  end

  defp explain(conn, sql, params) do
    {:ok, stmt} = Exqlite.Sqlite3.prepare(conn, "EXPLAIN QUERY PLAN " <> sql)
    :ok = Exqlite.Sqlite3.bind(stmt, params)
    {:ok, rows} = Exqlite.Sqlite3.fetch_all(conn, stmt)
    Enum.map(rows, &List.last/1)
  end

  defp uses_writer_index?(details) do
    Enum.any?(details, &(&1 =~ ~r/SEARCH entries USING (COVERING )?INDEX entries_by_writer/)) and
      not Enum.any?(details, &(&1 =~ ~r/^SCAN entries|INTEGER PRIMARY KEY/))
  end

  # ── I3: the sidecar binds to the database file instance ────────────────────

  test "a data dir copied file-by-file (log + sidecar) is a new incarnation: the copied F is refused", %{root: root} do
    log_id = uuid()
    src_dir = Path.join(root, "src-copy")
    store = new_store(src_dir, log_id)
    for n <- 1..6, do: append!(store, uuid(), n)
    {:ok, f} = LocalSQLite.local_frontier(store, log_id, 4)
    {:ok, path} = LocalSQLite.sidecar_path(store, log_id)
    :ok = LocalSidecar.write(path, LocalFrontier.encode(f))
    :ok = LocalSQLite.close(store)

    # positive control: the SAME file reopened still verifies F
    {:ok, reopened} = LocalSQLite.open(src_dir, log_id)
    assert {:ok, %{through: 6}} = LocalSQLite.open_local_suffix(reopened, log_id, f)
    :ok = LocalSQLite.close(reopened)

    dst_dir = Path.join(root, "dst-copy")
    File.mkdir_p!(dst_dir)
    for name <- [log_id <> ".sqlite3", log_id <> ".checkpoint"], do: File.cp!(Path.join(src_dir, name), Path.join(dst_dir, name))
    {:ok, copy} = LocalSQLite.open(dst_dir, log_id)
    {:ok, copied_path} = LocalSQLite.sidecar_path(copy, log_id)
    {:ok, bytes} = LocalSidecar.read(copied_path, 1_000_000)
    {:ok, copied_f} = LocalFrontier.decode(bytes)
    assert {:error, {:local_frontier_refused, :incarnation_mismatch}} = LocalSQLite.open_local_suffix(copy, log_id, copied_f)
    assert {:error, {:local_frontier_refused, :incarnation_mismatch}} = LocalSuffix.read(log_of(copy), copied_f)
  end

  # ── minor: coordinate_missing, symlinked sidecar ───────────────────────────

  test "an F at an arrival with no stored row is :coordinate_missing", %{root: root} do
    store = new_store(Path.join(root, "gap"), uuid())
    w = uuid()
    for n <- 1..3, do: append!(store, w, n)
    :ok = Exqlite.Sqlite3.execute(store.conn, "UPDATE sqlite_sequence SET seq = seq + 5 WHERE name = 'entries'")
    for n <- 4..5, do: append!(store, w, n)
    assert Enum.map(all_rows(store), & &1.arrival_seq) == [1, 2, 3, 9, 10]
    assert {:error, {:local_frontier_refused, :coordinate_missing}} = LocalSQLite.local_frontier(store, store.log_id, 6)
    {:ok, f} = LocalSQLite.local_frontier(store, store.log_id, 3)
    forged = %{f | arrival_seq: 6}
    assert {:error, {:local_frontier_refused, :coordinate_missing}} = LocalSuffix.read(log_of(store), forged)
  end

  test "a symlinked sidecar is refused, even to an owner-only file", %{root: root} do
    target = Path.join(root, "real-file")
    File.write!(target, "bytes")
    File.chmod!(target, 0o600)
    path = LocalSidecar.path(root, uuid())
    :ok = File.ln_s(target, path)
    assert {:error, :not_regular_file} = LocalSidecar.read(path, 100)
  end

  test "sidecar temporaries live in an owner-only dir and clear/1 removes leftovers", %{root: root} do
    path = LocalSidecar.path(root, uuid())
    :ok = LocalSidecar.write(path, "x")
    tmp_dir = Path.join(root, ".checkpoint-tmp")
    assert {:ok, %File.Stat{mode: mode, type: :directory}} = File.stat(tmp_dir)
    assert Bitwise.band(mode, 0o777) == 0o700
    leftover = Path.join(tmp_dir, Path.basename(path) <> ".tmp-77")
    File.write!(leftover, "torn")
    :ok = LocalSidecar.clear(path)
    refute File.exists?(leftover)
    refute File.exists?(path)
  end
end

defmodule Commonplace.Log.LocalSuffixTest.PageSource do
  @moduledoc false
  # A wrapper page source over a real bound log. `mode`:
  #   :pass                 delegate unchanged (control)
  #   :drop_one             drop the second row of the first multi-row page
  #   :repeat_one           repeat a row of the first multi-row page (dropping its last)
  #   :leak_prefix          prepend the row at F to the first page
  #   :append_between_pages append one entry to the log before every page after the first
  alias Commonplace.Log.LocalSuffix

  def local_frontier({inner, _mode, _}, _log_id, arrival), do: LocalSuffix.local_frontier(inner, arrival)
  def open_local_suffix({inner, _, _}, log_id, f), do: inner.module.open_local_suffix(inner.store, log_id, f)

  def read_local_page({_inner, :refuse_pages, _}, _log_id, _after, _through, _limit),
    do: raise("a page was read")

  def read_local_page({inner, mode, _}, log_id, after_arrival, through, limit) do
    if mode == :append_between_pages and after_arrival > 10 do
      {:ok, _} = Commonplace.LogStore.SQLite.append(log_id, nil, %{"between" => after_arrival}, "2026-10-04T00:00:00Z")
    end

    with {:ok, page} <- inner.module.read_local_page(inner.store, log_id, after_arrival, through, limit) do
      first? = Process.get({__MODULE__, :done}) != true

      entries =
        case {mode, page.entries} do
          {:drop_one, [a, _b | rest]} when first? -> mark([a | rest])
          {:repeat_one, [a | rest]} when first? and rest != [] -> mark([a, a | Enum.drop(rest, -1)])
          {:leak_prefix, es} when first? ->
            {:ok, %{entries: [prev]}} = inner.module.read_local_page(inner.store, log_id, after_arrival - 1, after_arrival, 1)
            mark([prev | es])
          {_, es} -> es
        end

      if page.next_after_arrival == nil, do: Process.delete({__MODULE__, :done})
      {:ok, %{page | entries: entries}}
    end
  end

  defp mark(entries) do
    Process.put({__MODULE__, :done}, true)
    entries
  end
end
