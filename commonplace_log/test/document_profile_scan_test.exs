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

  def read_writer(handle, _opts),
    do:
      {:ok, %{entries: Enum.map(handle.store.rows, &%{canonical_bytes: &1}), next_after_seq: nil}}

  def merge_with_epoch(_handle, entries, _epoch), do: {:ok, %{canonical_entries: entries}}
end

defmodule Commonplace.Log.DocumentProfileScanTest do
  use ExUnit.Case, async: false
  alias Commonplace.Log.{DocumentProfile, Entry, ScanFixtureLane}
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
