defmodule Commonplace.Log.MergeLawsTest do
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Commonplace.Log.{Engine, Jcs}
  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.Log.Test.SQLAudit

  @log_id "018f0000-0000-7000-8000-000000000001"
  @created_at ~U[2026-08-22 12:34:56Z]
  @cases 200

  defmodule StaleSubsetPersistence do
    @moduledoc false
    @behaviour Commonplace.Log.Persistence

    alias Commonplace.Log.Persistence.LocalSQLite

    def start_link(base, stale_counts) do
      Agent.start_link(fn -> %{base: base, outcomes: outcomes(stale_counts)} end)
    end

    def create_log(store, log_id, metadata), do: delegate(store, :create_log, [log_id, metadata])
    def take_lease(store, log_id), do: delegate(store, :take_lease, [log_id])
    def read_set(store, log_id, query), do: delegate(store, :read_set, [log_id, query])
    def frontier(store, log_id), do: delegate(store, :frontier, [log_id])

    def read_writer(store, log_id, writer_id, opts),
      do: delegate(store, :read_writer, [log_id, writer_id, opts])

    def tail_local(store, log_id, opts), do: delegate(store, :tail_local, [log_id, opts])

    def commit(store, plan) do
      Agent.get_and_update(store, fn state ->
        case state.outcomes do
          [true | rest] ->
            {{:error, :stale_revision}, %{state | outcomes: rest}}

          [false | rest] ->
            {LocalSQLite.commit(state.base, plan), %{state | outcomes: rest}}

          [] ->
            {LocalSQLite.commit(state.base, plan), state}
        end
      end)
    end

    defp delegate(store, function, args) do
      base = Agent.get(store, & &1.base)
      apply(LocalSQLite, function, [base | args])
    end

    defp outcomes(stale_counts) do
      Enum.flat_map(stale_counts, fn count -> List.duplicate(true, count) ++ [false] end)
    end
  end

  @tag :tmp_dir
  property "idempotence", %{tmp_dir: tmp_dir} do
    check all(fixture <- compatible_fixture(), max_runs: @cases, initial_seed: 510_501) do
      store = open_replica!(tmp_dir, unique_name("idempotence"))
      deliver_state!(store, fixture, :a)
      before = stored_state!(store)
      batch = duplicate_some(prefix_entries(fixture, :a), fixture.duplicate_stride)

      assert {:ok, %{inserted: 0, present: present}} = merge!(store, batch)
      assert present == length(batch)
      assert stored_state!(store) == before
      assert_audited!([store], prefix_entries(fixture, :a))
      close_all!([store])
    end
  end

  @tag :tmp_dir
  property "commutativity", %{tmp_dir: tmp_dir} do
    check all(fixture <- compatible_fixture(), max_runs: @cases, initial_seed: 510_502) do
      left = open_replica!(tmp_dir, unique_name("comm-left"))
      right = open_replica!(tmp_dir, unique_name("comm-right"))

      deliver_state!(left, fixture, :a)
      deliver_state!(right, fixture, :a)
      deliver_state!(left, fixture, :b)
      deliver_state!(left, fixture, :c)
      deliver_state!(right, fixture, :c)
      deliver_state!(right, fixture, :b)

      assert stored_bytes!(left) == stored_bytes!(right)

      expected =
        prefix_entries(fixture, :a) ++ prefix_entries(fixture, :b) ++ prefix_entries(fixture, :c)

      assert_audited!([left, right], expected)
      close_all!([left, right])
    end
  end

  # ⚠️ BOTH PROPERTIES BELOW HAVE HIT ExUnit's 60,000 ms WHOLE-TEST CEILING (2026-08-27).
  # If you are here because one of them timed out: the stacktraces terminated in SQLite
  # OPEN/CONFIGURE via open_replica!/2, NOT in merge logic, and the box carried an
  # unwatched periodic `mix run` doing disk work at the time. Before raising @cases or
  # adding a @tag timeout, read docs/measurements/2026-08-27-stale-retry-timeout-and-the-green-arm.md — it records
  # why a whole-suite pass/fail plus a whole-box memory line CANNOT tell "this property is
  # marginal against 60 s" apart from "opening a replica is slow while something else does
  # I/O", and names the per-test instrument the question actually needs.
  @tag :tmp_dir
  property "associativity", %{tmp_dir: tmp_dir} do
    check all(fixture <- compatible_fixture(), max_runs: @cases, initial_seed: 510_503) do
      ab = open_replica!(tmp_dir, unique_name("assoc-ab"))
      left = open_replica!(tmp_dir, unique_name("assoc-left"))
      bc = open_replica!(tmp_dir, unique_name("assoc-bc"))
      right = open_replica!(tmp_dir, unique_name("assoc-right"))

      deliver_state!(ab, fixture, :a)
      deliver_state!(ab, fixture, :b)
      ab_from_storage = stored_bytes_list!(ab)
      merge_chunks!(left, ab_from_storage, fixture)
      deliver_state!(left, fixture, :c)

      deliver_state!(bc, fixture, :b)
      deliver_state!(bc, fixture, :c)
      bc_from_storage = stored_bytes_list!(bc)

      deliver_state!(right, fixture, :a)
      merge_chunks!(right, bc_from_storage, fixture)

      assert stored_bytes!(left) == stored_bytes!(right)
      entries_a = prefix_entries(fixture, :a)
      entries_b = prefix_entries(fixture, :b)
      entries_c = prefix_entries(fixture, :c)
      assert_audited!([ab], entries_a ++ entries_b)
      assert_audited!([left, right], entries_a ++ entries_b ++ entries_c)
      assert_audited!([bc], entries_b ++ entries_c)
      close_all!([ab, left, bc, right])
    end
  end

  @tag :tmp_dir
  property "monotonicity", %{tmp_dir: tmp_dir} do
    check all(fixture <- compatible_fixture(), max_runs: @cases, initial_seed: 510_504) do
      store = open_replica!(tmp_dir, unique_name("monotonicity"))
      deliver_state!(store, fixture, :a)
      before_bytes = stored_bytes!(store)
      before_tips = tips!(store)

      deliver_state!(store, fixture, :b)
      after_bytes = stored_bytes!(store)
      after_tips = tips!(store)

      assert MapSet.subset?(before_bytes, after_bytes)

      Enum.each(before_tips, fn {writer_id, seq} ->
        assert Map.get(after_tips, writer_id, 0) >= seq
      end)

      assert_audited!([store], prefix_entries(fixture, :a) ++ prefix_entries(fixture, :b))
      close_all!([store])
    end
  end

  # See the timeout note above the "associativity" property and
  # docs/measurements/2026-08-27-stale-retry-timeout-and-the-green-arm.md
  @tag :tmp_dir
  property "stale-retry safety", %{tmp_dir: tmp_dir} do
    check all(scenario <- stale_scenario(), max_runs: @cases, initial_seed: 510_505) do
      control = open_replica!(tmp_dir, unique_name("stale-control"))
      injected = open_replica!(tmp_dir, unique_name("stale-injected"))
      {:ok, injector} = StaleSubsetPersistence.start_link(injected, scenario.stale_counts)

      run_operations!(LocalSQLite, control, scenario.operations)
      run_operations!(StaleSubsetPersistence, injector, scenario.operations)

      control_rows = normalized_rows!(control)
      injected_rows = normalized_rows!(injected)
      assert injected_rows == control_rows
      assert length(injected_rows) == scenario.expected_entry_count
      assert unique_coordinates?(injected_rows)
      assert gapless_in_order?(injected_rows)
      Enum.each([control, injected], &SQLAudit.assert_clean/1)
      Agent.stop(injector)
      close_all!([control, injected])
    end
  end

  defp compatible_fixture do
    gen all(
          writer_count <- integer(1..3),
          lengths <- fixed_list(List.duplicate(integer(0..4), writer_count)),
          prefixes_a <- prefix_vector(lengths),
          prefixes_b <- prefix_vector(lengths),
          prefixes_c <- prefix_vector(lengths),
          batch_size <- integer(1..4),
          duplicate_stride <- integer(0..3),
          reverse_batches? <- boolean()
        ) do
      histories =
        lengths
        |> Enum.with_index(1)
        |> Map.new(fn {length, writer_number} ->
          writer_id = uuid(writer_number)
          {writer_id, chain(writer_id, writer_number, length)}
        end)

      %{
        histories: histories,
        prefixes: %{a: prefixes_a, b: prefixes_b, c: prefixes_c},
        batch_size: batch_size,
        duplicate_stride: duplicate_stride,
        reverse_batches?: reverse_batches?
      }
    end
  end

  defp prefix_vector(lengths) do
    lengths |> Enum.map(&integer(0..&1)) |> fixed_list()
  end

  defp stale_scenario do
    gen all(
          merge_lengths <- fixed_list([integer(1..3), integer(1..3)]),
          append_lengths <- fixed_list([integer(1..3), integer(1..3)]),
          batch_size <- integer(1..3),
          duplicate? <- boolean(),
          stale_counts <-
            fixed_list([integer(1..3) | List.duplicate(integer(0..3), 15)])
        ) do
      merge_operations =
        merge_lengths
        |> Enum.with_index(11)
        |> Enum.flat_map(fn {length, writer_number} ->
          writer_id = uuid(writer_number)

          writer_id
          |> chain(writer_number, length)
          |> Enum.chunk_every(batch_size)
          |> Enum.map(fn batch ->
            batch = if duplicate?, do: batch ++ Enum.take(batch, 1), else: batch
            {:merge, batch}
          end)
        end)

      append_operations =
        append_lengths
        |> Enum.with_index(21)
        |> Enum.flat_map(fn {length, writer_number} ->
          Enum.map(1..length, fn seq ->
            {:append, uuid(writer_number), %{"operation" => "append", "ordinal" => seq}}
          end)
        end)

      %{
        operations: interleave(merge_operations, append_operations),
        stale_counts: stale_counts,
        expected_entry_count: Enum.sum(merge_lengths) + Enum.sum(append_lengths)
      }
    end
  end

  defp chain(_writer_id, _writer_number, 0), do: []

  defp chain(writer_id, writer_number, length) do
    {entries, _previous} =
      Enum.map_reduce(1..length, nil, fn seq, previous ->
        entry_id = uuid(writer_number * 100 + seq)

        bytes =
          Jcs.canonicalize(%{
            "version" => 1,
            "log_id" => @log_id,
            "entry_id" => entry_id,
            "writer_id" => writer_id,
            "writer_seq" => seq,
            "prev_entry_id" => previous,
            "created_at" => DateTime.to_iso8601(@created_at),
            "body" => %{"fixture_writer" => writer_number, "fixture_seq" => seq}
          })

        {bytes, entry_id}
      end)

    entries
  end

  defp prefix_entries(fixture, replica) do
    fixture.histories
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.zip(fixture.prefixes[replica])
    |> Enum.flat_map(fn {{_writer_id, entries}, prefix_length} ->
      Enum.take(entries, prefix_length)
    end)
  end

  defp deliver_state!(store, fixture, replica) do
    fixture
    |> prefix_entries(replica)
    |> duplicate_some(fixture.duplicate_stride)
    |> merge_chunks!(store, fixture)
  end

  defp merge_chunks!(entries, store, fixture) when is_list(entries) do
    merge_chunks!(store, entries, fixture)
  end

  defp merge_chunks!(store, entries, fixture) do
    entries
    |> Enum.chunk_every(fixture.batch_size)
    |> Enum.each(fn batch ->
      batch = if fixture.reverse_batches?, do: Enum.reverse(batch), else: batch
      assert {:ok, _result} = merge!(store, batch)
    end)
  end

  defp duplicate_some(entries, 0), do: entries

  defp duplicate_some(entries, stride) do
    entries
    |> Enum.with_index(1)
    |> Enum.flat_map(fn {entry, index} ->
      if rem(index, stride) == 0, do: [entry, entry], else: [entry]
    end)
  end

  defp merge!(store, entries), do: Engine.merge(LocalSQLite, store, @log_id, entries)

  defp run_operations!(adapter, store, operations) do
    Enum.each(operations, fn
      {:merge, entries} ->
        assert {:ok, _result} = Engine.merge(adapter, store, @log_id, entries)

      {:append, writer_id, body} ->
        assert {:ok, _result} =
                 Engine.append(adapter, store, @log_id, writer_id, body, @created_at)
    end)
  end

  defp interleave([], right), do: right
  defp interleave(left, []), do: left
  defp interleave([left | lefts], [right | rights]), do: [left, right | interleave(lefts, rights)]

  defp open_replica!(tmp_dir, name) do
    data_dir = Path.join(tmp_dir, name)
    {:ok, store} = LocalSQLite.open(data_dir, @log_id)
    :ok = LocalSQLite.create_log(store, @log_id, %{format_version: 1})
    store
  end

  defp stored_state!(store), do: {stored_bytes!(store), frontier!(store)}

  defp stored_bytes_list!(store) do
    store
    |> decoded_rows!()
    |> Enum.map(& &1.bytes)
  end

  defp stored_bytes!(store) do
    store |> stored_bytes_list!() |> MapSet.new()
  end

  defp frontier!(store) do
    {:ok, frontier} = LocalSQLite.frontier(store, @log_id)
    frontier
  end

  defp tips!(store) do
    {:ok, %{writers: writers}} = LocalSQLite.frontier(store, @log_id)
    Map.new(writers, &{&1.writer_id, &1.seq})
  end

  defp decoded_rows!(store) do
    {:ok, %{writers: writers}} = LocalSQLite.frontier(store, @log_id)

    Enum.flat_map(writers, fn tip ->
      {:ok, %{entries: entries}} =
        LocalSQLite.read_writer(store, @log_id, tip.writer_id,
          after_seq: 0,
          through_seq: tip.seq,
          limit: 1_000
        )

      Enum.map(entries, fn entry ->
        %{bytes: entry.canonical_bytes, decoded: Jason.decode!(entry.canonical_bytes)}
      end)
    end)
  end

  defp normalized_rows!(store) do
    store
    |> decoded_rows!()
    |> Enum.map(fn %{decoded: entry} ->
      Map.take(entry, ["writer_id", "writer_seq", "created_at", "body"])
    end)
    |> Enum.sort_by(&{&1["writer_id"], &1["writer_seq"]})
  end

  defp unique_coordinates?(rows) do
    coordinates = Enum.map(rows, &{&1["writer_id"], &1["writer_seq"]})
    length(coordinates) == coordinates |> MapSet.new() |> MapSet.size()
  end

  defp gapless_in_order?(rows) do
    rows
    |> Enum.group_by(& &1["writer_id"])
    |> Enum.all?(fn {_writer_id, entries} ->
      sequences = Enum.map(entries, & &1["writer_seq"])
      sequences == Enum.to_list(1..length(sequences))
    end)
  end

  defp assert_audited!(stores, expected_entries) do
    helper =
      if expected_entries == [],
        do: &SQLAudit.assert_clean_empty/1,
        else: &SQLAudit.assert_clean/1

    Enum.each(stores, helper)
  end

  defp close_all!(stores), do: Enum.each(stores, &LocalSQLite.close/1)

  defp uuid(number), do: "018f0000-0000-7000-8000-" <> hex12(number)

  defp hex12(number),
    do: number |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(12, "0")

  defp unique_name(prefix),
    do: prefix <> "-" <> Integer.to_string(System.unique_integer([:positive]))
end
