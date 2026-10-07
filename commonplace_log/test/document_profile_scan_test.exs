# Frozen production baseline, renamed only so both implementations run in one VM.
baseline_path = Path.join(__DIR__, "fixtures/document_profile_scan_baseline.ex.txt")
baseline_source = File.read!(baseline_path)

Code.compile_string(
  String.replace(
    baseline_source,
    "defmodule Commonplace.Log.DocumentProfile do",
    "defmodule Commonplace.Log.DocumentProfileScanBaseline do"
  ),
  baseline_path
)

defmodule Commonplace.Log.ScanFixtureLane do
  def frontier(handle), do: {:ok, %{writers: handle.store.tip}}
  def writer_id(handle), do: {:ok, handle.writer_id}

  def read_writer(handle, opts), do: {:ok, page(handle.store.rows, opts)}

  def merge_with_epoch(_handle, entries, _epoch), do: {:ok, %{canonical_entries: entries}}

  # A lane read honours its window, like every real lane (APPEND-RESCAN-1's
  # index reads only new seqs); the baseline only ever asks for 1..tip.
  def page(rows, opts) do
    after_seq = Keyword.fetch!(opts, :after_seq)
    through_seq = Keyword.get(opts, :through_seq) || length(rows)

    {page, more} =
      rows
      |> Enum.with_index(1)
      |> Enum.filter(fn {_row, seq} -> seq > after_seq and seq <= through_seq end)
      |> Enum.map(fn {row, seq} -> %{canonical_bytes: row, writer_seq: seq} end)
      |> Enum.split(Keyword.fetch!(opts, :limit))

    %{entries: page, next_after_seq: if(more == [], do: nil, else: List.last(page).writer_seq)}
  end
end

# A lane whose store is one live process, growing between prepares, that
# counts the rows it serves.
defmodule Commonplace.Log.GrowingScanLane do
  alias Commonplace.Log.ScanFixtureLane

  def frontier(handle) do
    case Agent.get(handle.store, & &1) do
      %{tip: tip} -> {:ok, %{writers: tip}}
      %{rows: []} -> {:ok, %{writers: []}}
      %{rows: rows} -> {:ok, %{writers: [%{writer_id: handle.writer_id, seq: length(rows), entry_id: tip_id(rows)}]}}
    end
  end

  # The tip's entry ID, read the way a store records it (a row that does not
  # decode leaves the tip as the store last recorded it: here, its seq's id).
  defp tip_id(rows) do
    case Jason.decode(List.last(rows)) do
      {:ok, %{"entry_id" => id}} -> id
      _ -> "00000000-0000-4000-8000-" <> String.pad_leading(Integer.to_string(1000 + length(rows), 16), 12, "0")
    end
  end

  def writer_id(handle), do: {:ok, handle.writer_id}

  def read_writer(handle, opts) do
    Agent.get_and_update(handle.store, fn state ->
      page = ScanFixtureLane.page(state.rows, opts)
      {{:ok, page}, %{state | served: state.served + length(page.entries)}}
    end)
  end

  def merge_with_epoch(_handle, entries, _epoch), do: {:ok, %{canonical_entries: entries}}
end

defmodule Commonplace.Log.DocumentProfileScanTest do
  use ExUnit.Case, async: false
  alias Commonplace.Log.{DocumentProfile, Entry, GrowingScanLane, ScanFixtureLane}
  alias Commonplace.Log.DocumentProfileScanBaseline, as: Baseline
  @time "2026-01-01T00:00:00Z"

  defp uuid(n),
    do:
      "00000000-0000-4000-8000-" <>
        String.pad_leading(String.downcase(Integer.to_string(n, 16)), 12, "0")

  defp handle(rows) do
    tip =
      case List.last(rows) do
        nil ->
          []

        raw ->
          last = Jason.decode!(raw)
          [%{writer_id: uuid(2), seq: length(rows), entry_id: Map.get(last, "entry_id")}]
      end

    %DocumentProfile.Handle{
      log_id: uuid(1),
      writer_id: uuid(2),
      adapter: ScanFixtureLane,
      lane: ScanFixtureLane,
      lease: 1,
      retry_context: :binary.copy(<<9>>, 32),
      store: %{rows: rows, tip: tip}
    }
  end

  defp history(n), do: extend([], n)
  defp extend(rows, 0), do: rows

  defp extend(rows, n) do
    Enum.reduce(1..n, rows, fn _, acc ->
      seq = length(acc) + 1

      previous =
        case List.last(acc) do
          nil -> nil
          raw -> Jason.decode!(raw)["entry_id"]
        end

      entry = %{
        "version" => 2,
        "log_id" => uuid(1),
        "writer_id" => uuid(2),
        "entry_id" => uuid(1000 + seq),
        "writer_seq" => seq,
        "prev_entry_id" => previous,
        "created_at" => @time,
        "operation_id" => "history-#{seq}",
        "body" => %{"n" => seq}
      }

      {:ok, canonical} = Entry.validate_entry(Jason.encode!(entry))
      acc ++ [canonical]
    end)
  end

  defp evaluate(mod, h, bodies, op, time \\ @time) do
    h = if mod == Baseline, do: struct(Baseline.Handle, Map.from_struct(h)), else: h

    try do
      with {:ok, prepared} <- mod.prepare_append(h, bodies, operation_id: op, created_at: time) do
        mod.commit_prepared(h, prepared)
      end
    catch
      kind, reason ->
        {m, f, args, _} = hd(__STACKTRACE__)
        m = if m == Baseline, do: DocumentProfile, else: m
        {:native, kind, reason, {m, f, if(is_list(args), do: length(args), else: args)}}
    end
  end

  defp same(h, bodies, op, time \\ @time) do
    expected = evaluate(Baseline, h, bodies, op, time)
    assert evaluate(DocumentProfile, h, bodies, op, time) == expected
    expected
  end

  defp batch(h, bodies, op, time \\ @time) do
    {:ok, %{canonical_entries: entries}} = evaluate(Baseline, h, bodies, op, time)
    entries
  end

  test "exact multi-entry retry retains positional coordinates across decimal widths" do
    for prefix_count <- [0, 8, 9, 98, 99] do
      prefix = history(prefix_count)
      bodies = [%{"text" => "alpha"}, %{"text" => "βeta"}]
      entries = batch(handle(prefix), bodies, "target")
      h = handle(extend(prefix ++ entries, 3))
      assert {:ok, %{canonical_entries: ^entries}} = same(h, bodies, "target")
    end
  end

  test "mixed versions and reused operation IDs still require exact first matching bytes" do
    [first | rest] = history(12)

    v1 =
      first
      |> Jason.decode!()
      |> Map.put("version", 1)
      |> Map.delete("operation_id")
      |> Jason.encode!()

    {:ok, v1} = Entry.validate_entry(v1)
    prefix = [v1 | rest]
    bodies = [%{"value" => 2}]
    wrong = batch(handle(prefix), [%{"value" => 1}], "reused")
    right = batch(handle(prefix ++ wrong), bodies, "reused")
    h = handle(extend(prefix ++ wrong ++ right, 2))
    assert {:ok, %{canonical_entries: ^right}} = same(h, bodies, "reused")
    assert {:ok, _} = same(h, bodies, "absent")
  end

  test "partial batch body mismatch and timestamp mismatch cannot become a replay" do
    prefix = history(10)
    bodies = [%{"n" => 1}, %{"n" => 2}]
    full = batch(handle(prefix), bodies, "target")

    assert {:ok, %{canonical_entries: different}} =
             same(handle(prefix ++ Enum.take(full, 1)), bodies, "target")

    refute different == full

    assert {:ok, %{canonical_entries: different}} =
             same(handle(prefix ++ full), [%{"n" => 3}], "target")

    refute different == full

    assert {:ok, %{canonical_entries: different}} =
             same(handle(prefix ++ full), bodies, "target", "2026-01-02T00:00:00Z")

    refute different == full
  end

  test "oversize largest candidate falls back and preserves earlier seq1 exact replay" do
    [empty] = batch(handle([]), [%{"text" => ""}], "target")
    bodies = [%{"text" => String.duplicate("x", 1_048_576 - byte_size(empty))}]
    [large] = batch(handle([]), bodies, "target")
    assert byte_size(large) == 1_048_576
    h = handle(extend([large], 9))
    assert {:ok, %{canonical_entries: [^large]}} = same(h, bodies, "target")
  end

  test "9 to10 size boundary preserves earlier replay when certificate fails" do
    prefix = history(8)
    [empty] = batch(handle(prefix), [%{"text" => ""}], "target")
    bodies = [%{"text" => String.duplicate("x", 1_048_576 - byte_size(empty))}]
    [large] = batch(handle(prefix), bodies, "target")
    assert byte_size(large) == 1_048_576
    h = handle(extend(prefix ++ [large], 1))
    assert {:ok, %{canonical_entries: [^large]}} = same(h, bodies, "target")
  end

  @tag :prepare_scan_continuation
  test "first candidate validation error is retained even when operation is absent" do
    h = handle(history(12))
    bodies = [%{"text" => String.duplicate("x", 1_048_576)}]
    assert {:native, :error, {:case_clause, {:error, {:entry_too_large, _}}},
            {DocumentProfile, :find_or_build_entries, 6}} = same(h, bodies, "absent")
  end

  @tag :prepare_scan_continuation
  test "malformed history and missing predecessor retain native fallback failures" do
    rows = history(4)
    h = handle(rows)
    broken_json = put_in(h.store.rows, ["{" | tl(rows)])
    assert {:native, :error, %Jason.DecodeError{}, _} = same(broken_json, [%{"n" => 1}], "absent")
    missing_id = put_in(h.store.rows, [hd(rows), "{}" | Enum.drop(rows, 2)])
    assert {:native, :error, {:badkey, "entry_id"}, {:erlang, :map_get, 2}} = same(missing_id, [%{"n" => 1}], "absent")

    malformed_id =
      rows |> Enum.at(1) |> Jason.decode!() |> Map.put("entry_id", "bad") |> Jason.encode!()

    h = put_in(h.store.rows, [hd(rows), malformed_id | Enum.drop(rows, 2)])
    assert {:native, :error, {:case_clause, {:error, {:invalid_entry, _}}},
            {DocumentProfile, :find_or_build_entries, 6}} = same(h, [%{"n" => 1}], "absent")
  end

  test "certificate encoding exception defers to original scan native exception" do
    h = %{handle(history(4)) | log_id: self()}
    assert {:native, :error, %ArgumentError{}, _} = same(h, [%{"n" => 1}], "absent")
  end

  test "fixed differential matrix covers empty and short histories and batch sizes" do
    for count <- [0, 1, 2, 9, 10, 31],
        bodies <- [[%{"u" => "é\n"}], [%{"a" => 1}, %{"b" => false}]] do
      prefix = history(count)
      assert {:ok, %{canonical_entries: new}} = same(handle(prefix), bodies, "target")
      assert {:ok, %{canonical_entries: ^new}} = same(handle(prefix ++ new), bodies, "target")
    end
  end

  defp growing(rows, context) do
    {:ok, store} = Agent.start_link(fn -> %{rows: rows, served: 0} end)

    h = %DocumentProfile.Handle{
      log_id: uuid(1),
      writer_id: uuid(2),
      adapter: GrowingScanLane,
      lane: GrowingScanLane,
      lease: 1,
      retry_context: :binary.copy(<<context>>, 32),
      store: store
    }

    served = fn mod, bodies, op ->
      Agent.update(store, &%{&1 | served: 0})
      result = evaluate(mod, h, bodies, op)
      {result, Agent.get(store, & &1.served)}
    end

    {store, h, served}
  end

  test "APPEND-RESCAN-1: a growing lane reads only its new seqs and matches the baseline" do
    # From an EMPTY lane, so seq 1 is a prepared (derived-id) entry a retry can match.
    {store, _h, served} = growing([], 7)

    appended =
      for n <- 1..60, reduce: [] do
        appended ->
          bodies = if rem(n, 3) == 0, do: [%{"n" => n}, %{"m" => n}], else: [%{"n" => n}]
          {expected, baseline_rows} = served.(Baseline, bodies, "grow-#{n}")
          {actual, rows} = served.(DocumentProfile, bodies, "grow-#{n}")
          assert actual == expected
          {:ok, %{canonical_entries: entries}} = actual
          lane = Agent.get(store, &length(&1.rows))
          assert baseline_rows == lane
          # Prepares whose candidate starts at seq 1 take the original path
          # (no index); the first indexed prepare (n = 4 here) builds it. From
          # then on: the seqs appended since the last prepare (at most 2) plus
          # one predecessor row.
          if n > 4, do: assert(rows <= 3, "prepare #{n} read #{rows} rows of #{lane}")

          # Exact retries -- of seq 1, of a 2-body batch, of a recent single --
          # are found, as by the baseline, from a window read only.
          if rem(n, 10) == 0 do
            for {old_n, old_bodies, old_entries} <- [hd(appended), Enum.at(appended, 2), Enum.at(appended, 3)] do
              {retry, retry_rows} = served.(DocumentProfile, old_bodies, "grow-#{old_n}")
              assert retry == {:ok, %{canonical_entries: old_entries}}
              assert retry == elem(served.(Baseline, old_bodies, "grow-#{old_n}"), 0)
              # The certifying predecessor, then a window of b+1 rows at each
              # seq carrying the operation ID (every entry of a b-body batch).
              b = length(old_bodies)
              assert retry_rows <= 1 + b * (b + 1)
            end

            assert length(elem(Enum.at(appended, 2), 1)) == 2
          end

          Agent.update(store, &%{&1 | rows: &1.rows ++ entries})
          appended ++ [{n, bodies, entries}]
      end

    assert length(appended) == 60
  end

  test "APPEND-RESCAN-1: history before the tip changes while the lane grows (chain check)" do
    {store, h, _served} = growing(history(40), 6)
    bodies = [%{"n" => "x"}]
    # Index seqs 1..40 (uuid(1001)..uuid(1040)).
    assert {:ok, _} = evaluate(DocumentProfile, h, bodies, "x")
    # Same handle: seq 40 is now operation "x" itself and the lane grows to 45.
    # Seqs 41.. carry the same ids as before, so only seq 41's prev_entry_id
    # (the new seq 40's id) shows that the indexed history is not this one.
    prefix = history(39)
    swapped = extend(prefix ++ batch(handle(prefix), bodies, "x"), 5)
    Agent.update(store, &%{&1 | rows: swapped})
    expected = evaluate(Baseline, h, bodies, "x")
    assert {:ok, %{canonical_entries: [Enum.at(swapped, 39)]}} == expected
    assert evaluate(DocumentProfile, h, bodies, "x") == expected
  end

  test "APPEND-RESCAN-1: an undecodable row: retries match the baseline, one lane read each" do
    rows = history(20)
    {store, h, served} = growing(List.replace_at(rows, 4, "{"), 5)
    # The store's tip is unchanged; seq 5 no longer decodes.
    for {op, attempt} <- Enum.with_index(["history-3", "absent", "history-3"]) do
      {expected, baseline_rows} = served.(Baseline, [%{"n" => 3}], op)
      {actual, rows_read} = served.(DocumentProfile, [%{"n" => 3}], op)
      assert {:native, :error, %Jason.DecodeError{}, _} = expected
      assert actual == expected
      # The first prepare tries to build (one extra read); the negative entry
      # then keeps every later prepare at the baseline's single read.
      if attempt == 0,
        do: assert(rows_read <= 2 * baseline_rows),
        else: assert(rows_read == baseline_rows)
    end

    assert Agent.get(store, &length(&1.rows)) == 20
  end

  test "APPEND-RESCAN-1: lane_index: false reads the lane as before and matches the baseline" do
    {_store, h, _served} = growing(history(30), 4)
    {:ok, store2} = Agent.start_link(fn -> %{rows: history(30), served: 0} end)
    h = %{h | store: store2}

    for op <- ["a", "b", "history-7"] do
      Agent.update(store2, &%{&1 | served: 0})
      expected = evaluate(Baseline, h, [%{"n" => 1}], op)
      baseline_rows = Agent.get(store2, & &1.served)
      Agent.update(store2, &%{&1 | served: 0})
      h_bypass = h

      actual =
        with {:ok, prepared} <-
               DocumentProfile.prepare_append(h_bypass, [%{"n" => 1}],
                 operation_id: op,
                 created_at: @time,
                 lane_index: false
               ),
             do: DocumentProfile.commit_prepared(h_bypass, prepared)

      assert actual == expected
      assert Agent.get(store2, & &1.served) == baseline_rows
    end

    assert {:error, {:invalid_prepared_append, %{reason: :lane_index_must_be_boolean}}} =
             DocumentProfile.prepare_append(h, [%{"n" => 1}], operation_id: "a", created_at: @time, lane_index: 1)
  end

  test "APPEND-RESCAN-1: a tip without an entry ID falls back like the baseline" do
    {store, h, _served} = growing(history(12), 3)
    Agent.update(store, &Map.put(&1, :tip, [%{writer_id: uuid(2), seq: 12}]))
    expected = evaluate(Baseline, h, [%{"n" => 1}], "absent")
    assert {:native, :error, {:badkey, :entry_id, _}, _} = expected
    assert evaluate(DocumentProfile, h, [%{"n" => 1}], "absent") == expected
  end

  test "APPEND-RESCAN-1: an index that no longer chains onto the tip is rebuilt" do
    {:ok, store} = Agent.start_link(fn -> %{rows: history(41), served: 0} end)

    h = %DocumentProfile.Handle{
      log_id: uuid(1),
      writer_id: uuid(2),
      adapter: GrowingScanLane,
      lane: GrowingScanLane,
      lease: 1,
      retry_context: :binary.copy(<<8>>, 32),
      store: store
    }

    bodies = [%{"n" => "swapped"}]
    assert {:ok, _} = evaluate(DocumentProfile, h, bodies, "swapped")
    # Same handle, same length, a different seq 41 that IS this operation.
    swapped = history(40) ++ batch(handle(history(40)), bodies, "swapped")
    Agent.update(store, &%{&1 | rows: swapped})
    expected = evaluate(Baseline, h, bodies, "swapped")
    assert {:ok, %{canonical_entries: [hd(Enum.drop(swapped, 40))]}} == expected
    assert evaluate(DocumentProfile, h, bodies, "swapped") == expected
  end

  @tag :prepare_scan_performance
  test "absent operation avoids repeated deep candidate construction" do
    measurements =
      for count <- [64, 128] do
        h = handle(history(count))
        bodies = [%{"text" => String.duplicate("x", 4096)}]

        measured =
          for mod <- [Baseline, DocumentProfile] do
            {:reductions, before} = Process.info(self(), :reductions)
            start = System.monotonic_time(:microsecond)
            outcome = evaluate(mod, h, bodies, "absent")
            elapsed = System.monotonic_time(:microsecond) - start
            {:reductions, after_count} = Process.info(self(), :reductions)
            {outcome, %{reductions: after_count - before, elapsed_us: elapsed}}
          end

        [{old, old_metrics}, {new, new_metrics}] = measured
        assert {:ok, %{canonical_entries: [_]}} = old
        assert old == new
        %{history_rows: count, baseline: old_metrics, candidate: new_metrics, prepared_equal: true}
      end

    if output = System.get_env("PREPARE_SCAN_RESULTS"),
      do: File.write!(output, Jason.encode!(measurements))

    for m <- measurements do
      assert m.candidate.reductions < div(m.baseline.reductions, 2)
    end
  end
end
