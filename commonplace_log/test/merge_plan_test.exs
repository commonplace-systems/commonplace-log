defmodule Commonplace.Log.MergePlanTest.Fixtures do
  @moduledoc false
  # Fixture builders shared by the compile-time table and the runtime tests.

  # Deterministic entry maker: the fake canonical bytes encode every argument,
  # so two calls with identical arguments are byte-equal and any argument
  # difference (including payload alone, for collision/fork rows) changes the
  # bytes. IDs are opaque strings to the classifier; no need for real UUIDs.
  def mk(writer_id, writer_seq, entry_id, prev_entry_id, payload \\ "") do
    %{
      entry_id: entry_id,
      writer_id: writer_id,
      writer_seq: writer_seq,
      prev_entry_id: prev_entry_id,
      canonical_bytes:
        "#{writer_id}/#{writer_seq}/#{entry_id}/#{prev_entry_id || "null"}/#{payload}"
    }
  end

  # Store state for a row: entries already present, tips derived from them.
  def store_of(present) do
    existing =
      Enum.reduce(present, %{}, fn e, acc ->
        Map.update(
          acc,
          e.writer_id,
          %{seq: e.writer_seq, entry_id: e.entry_id},
          fn tip ->
            if e.writer_seq > tip.seq,
              do: %{seq: e.writer_seq, entry_id: e.entry_id},
              else: tip
          end
        )
      end)

    present_by_coord = fn w, s ->
      case Enum.find(present, &(&1.writer_id == w and &1.writer_seq == s)) do
        nil -> nil
        e -> e.canonical_bytes
      end
    end

    present_by_id = fn id ->
      case Enum.find(present, &(&1.entry_id == id)) do
        nil ->
          nil

        e ->
          %{writer_id: e.writer_id, writer_seq: e.writer_seq, bytes: e.canonical_bytes}
      end
    end

    {existing, present_by_coord, present_by_id}
  end
end

defmodule Commonplace.Log.MergePlanTest do
  @moduledoc """
  Table-driven tests for the pure merge classifier (spec §9.3 rules 1–6 and
  the three merge error codes, §6.3 entry-ID collision, §8 invariants
  3/4/9/10). Ported row-for-row from `worker/test/merge-plan.test.ts` — the
  two suites must stay in lockstep; a row changed on one side must change on
  the other.
  """
  use ExUnit.Case, async: true

  alias Commonplace.Log.MergePlan
  alias Commonplace.Log.MergePlanTest.Fixtures

  import Fixtures, only: [mk: 4, store_of: 1]

  # --- match helper --------------------------------------------------------

  # Partial structural match, mirroring vitest's `toMatchObject`: maps match
  # by subset (recursively), lists match by length and elementwise, everything
  # else by equality.
  defp matches?(actual, expected) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {k, v} ->
      Map.has_key?(actual, k) and matches?(Map.fetch!(actual, k), v)
    end)
  end

  defp matches?(actual, expected) when is_list(expected) and is_list(actual) do
    length(actual) == length(expected) and
      Enum.zip(actual, expected) |> Enum.all?(fn {a, e} -> matches?(a, e) end)
  end

  defp matches?({:ok, a}, {:ok, e}), do: matches?(a, e)
  defp matches?({:error, {code, a}}, {:error, {code, e}}), do: matches?(a, e)
  defp matches?(actual, expected), do: actual == expected

  defp assert_matches(actual, expected) do
    unless matches?(actual, expected) do
      flunk("""
      expected (partial): #{inspect(expected, pretty: true)}
      actual: #{inspect(actual, pretty: true)}
      """)
    end
  end

  # --- fixtures ------------------------------------------------------------

  # Writer W with three committed entries; the standard "existing store" for
  # most rows. Writer ids chosen so sort order is obvious in multi-writer rows.
  @w "writer-mmm"
  @w1 Fixtures.mk(@w, 1, "id-w1", nil)
  @w2 Fixtures.mk(@w, 2, "id-w2", "id-w1")
  @w3 Fixtures.mk(@w, 3, "id-w3", "id-w2")

  # --- the table -----------------------------------------------------------

  # Each row: {name, present, batch, expected (partial outcome)}. Lockstep
  # with the TS twin's 19-row table, same order, same names (adapted).
  @rows [
    {
      "empty batch is ok with zero plans (§9.3 vacuous case)",
      [@w1, @w2],
      [],
      {:ok, %{per_writer: [], present_count: 0}}
    },
    {
      "fresh writer starting at seq 1 with chained prevs (§9.3 rules 3–5)",
      [],
      [Fixtures.mk("wf", 1, "f1", nil), Fixtures.mk("wf", 2, "f2", "f1")],
      {:ok,
       %{
         present_count: 0,
         per_writer: [
           %{
             writer_id: "wf",
             first_new_seq: 1,
             new_entries: [%{entry_id: "f1"}, %{entry_id: "f2"}]
           }
         ]
       }}
    },
    {
      "fresh writer NOT starting at 1 → writer_gap with expected_seq 1 and nil tip",
      [],
      [Fixtures.mk("wf", 2, "f2", "f1")],
      {:error, {:writer_gap, %{writer_id: "wf", expected_seq: 1, tip_entry_id: nil}}}
    },
    {
      "extension at tip+1 naming the tip in prev_entry_id (§9.3 rules 3–4)",
      [@w1, @w2],
      [Fixtures.mk(@w, 3, "id-w3", "id-w2")],
      {:ok,
       %{
         present_count: 0,
         per_writer: [
           %{writer_id: @w, first_new_seq: 3, new_entries: [%{entry_id: "id-w3"}]}
         ]
       }}
    },
    {
      "extension at tip+1 with wrong prev_entry_id → writer_fork (§9.3 rule 4: coordinate holds a different chain)",
      [@w1, @w2],
      [Fixtures.mk(@w, 3, "id-x3", "id-w1")],
      {:error, {:writer_fork, %{writer_id: @w, seq: 3}}}
    },
    {
      "batch wholly at/below tip and byte-equal → all present, no plan (§9.3 rule 2, invariant 9)",
      [@w1, @w2, @w3],
      [@w1, @w2, @w3],
      {:ok, %{per_writer: [], present_count: 3}}
    },
    {
      "partially duplicate batch: present prefix counted, new suffix planned",
      [@w1, @w2],
      [@w2, Fixtures.mk(@w, 3, "id-w3", "id-w2")],
      {:ok,
       %{
         present_count: 1,
         per_writer: [
           %{writer_id: @w, first_new_seq: 3, new_entries: [%{entry_id: "id-w3"}]}
         ]
       }}
    },
    {
      "first new entry beyond tip+1 → writer_gap carrying the receiver's tip (§9.3 error 1, §15.5)",
      [@w1, @w2],
      [Fixtures.mk(@w, 4, "id-w4", "id-w3")],
      {:error, {:writer_gap, %{writer_id: @w, expected_seq: 3, tip_entry_id: "id-w2"}}}
    },
    {
      "different bytes at an occupied coordinate → writer_fork (§9.3 error 2)",
      [@w1, @w2],
      [Fixtures.mk(@w, 2, "id-x2", "id-w1", "divergent")],
      {:error, {:writer_fork, %{writer_id: @w, seq: 2}}}
    },
    {
      "existing entry_id with different canonical bytes → entry_id_collision (§9.3 error 3, §6.3)",
      [@w1, @w2],
      # A structurally valid extension that reuses id-w1 for different bytes.
      [Fixtures.mk(@w, 3, "id-w1", "id-w2", "reused-id")],
      {:error, {:entry_id_collision, %{entry_id: "id-w1"}}}
    },
    {
      "same entry_id at the SAME coordinate with different bytes → entry_id_collision, not fork (§6.3 MUST)",
      [@w1, @w2],
      # Same id, same (writer, seq) as the stored w2, but tampered bytes.
      # Kills the mutant that drops the byte-equality clause from the
      # stored-id check: without it this row degrades to writer_fork.
      [Fixtures.mk(@w, 2, "id-w2", "id-w1", "tampered")],
      {:error, {:entry_id_collision, %{entry_id: "id-w2"}}}
    },
    {
      "same entry_id, same bytes, same coordinate → duplicate, present, NOT a collision (§9.3 rule 2)",
      [@w1, @w2],
      [Fixtures.mk(@w, 2, "id-w2", "id-w1")],
      {:ok, %{per_writer: [], present_count: 1}}
    },
    {
      "intra-batch sequence hole after a valid first new entry → writer_gap at the hole (§9.3 rule 5)",
      [@w1, @w2],
      [
        Fixtures.mk(@w, 3, "id-w3", "id-w2"),
        Fixtures.mk(@w, 4, "id-w4", "id-w3"),
        Fixtures.mk(@w, 6, "id-w6", "id-w5")
      ],
      {:error, {:writer_gap, %{writer_id: @w, expected_seq: 5, tip_entry_id: "id-w2"}}}
    },
    {
      "intra-batch prev_entry_id not naming the preceding batch entry → invalid_batch (§9.3 rule 5)",
      [@w1, @w2],
      [Fixtures.mk(@w, 3, "id-w3", "id-w2"), Fixtures.mk(@w, 4, "id-w4", "id-BOGUS")],
      {:error, {:invalid_batch, %{}}}
    },
    {
      "intra-batch entry_id reused at different coordinates → entry_id_collision (§6.3)",
      [],
      [Fixtures.mk("wf", 1, "f-dup", nil), Fixtures.mk("wf", 2, "f-dup", "f-dup")],
      {:error, {:entry_id_collision, %{entry_id: "f-dup"}}}
    },
    {
      "intra-batch duplicate coordinate with different bytes → writer_fork",
      [],
      [Fixtures.mk("wf", 1, "f1", nil), Fixtures.mk("wf", 1, "f1b", nil)],
      {:error, {:writer_fork, %{writer_id: "wf", seq: 1}}}
    },
    {
      "exact duplicate entry within one batch → deduplicated, copy counted as present",
      [],
      [Fixtures.mk("wf", 1, "f1", nil), Fixtures.mk("wf", 1, "f1", nil)],
      {:ok,
       %{
         present_count: 1,
         per_writer: [
           %{writer_id: "wf", first_new_seq: 1, new_entries: [%{entry_id: "f1"}]}
         ]
       }}
    },
    {
      "multi-writer batch where one writer fails → whole batch fails with that writer's error, no partial plan",
      [@w1, @w2],
      [
        # "aaa" sorts before W and is entirely valid; the classifier must
        # still refuse the whole batch for W's gap. An error outcome carries
        # no per_writer, so no partial plan can escape (§8 invariant 10).
        Fixtures.mk("aaa", 1, "a1", nil),
        Fixtures.mk(@w, 4, "id-w4", "id-w3")
      ],
      {:error, {:writer_gap, %{writer_id: @w, expected_seq: 3, tip_entry_id: "id-w2"}}}
    },
    {
      "multi-writer all-valid batch → one plan per writer, sorted by writer_id",
      [@w1, @w2],
      [
        # Deliberately fed in reverse writer order.
        Fixtures.mk("zzz", 1, "z1", nil),
        Fixtures.mk(@w, 3, "id-w3", "id-w2"),
        Fixtures.mk("aaa", 1, "a1", nil),
        Fixtures.mk("aaa", 2, "a2", "a1")
      ],
      {:ok,
       %{
         present_count: 0,
         per_writer: [
           %{
             writer_id: "aaa",
             first_new_seq: 1,
             new_entries: [%{entry_id: "a1"}, %{entry_id: "a2"}]
           },
           %{writer_id: @w, first_new_seq: 3, new_entries: [%{entry_id: "id-w3"}]},
           %{writer_id: "zzz", first_new_seq: 1, new_entries: [%{entry_id: "z1"}]}
         ]
       }}
    }
  ]

  # --- runner --------------------------------------------------------------

  describe "plan_merge classifies batches per spec §9.3" do
    test "anti-vacuity: the table has at least 14 rows" do
      assert length(@rows) >= 14
    end

    # The TS twin has 19 table rows; the tables must not drift apart.
    test "lockstep: the table has exactly the TS twin's 19 rows" do
      assert length(@rows) == 19
    end

    for {{name, present, batch, expected}, index} <- Enum.with_index(@rows) do
      @row {present, batch, expected}
      test "row #{index}: #{name}" do
        {present, batch, expected} = @row
        {existing, present_by_coord, present_by_id} = store_of(present)
        outcome = MergePlan.plan_merge(batch, existing, present_by_coord, present_by_id)
        assert_matches(outcome, expected)
      end
    end

    test "batch order does not matter: shuffled input classifies identically (§9.3 rule 1)" do
      batch = [
        mk(@w, 3, "id-w3", "id-w2"),
        mk(@w, 4, "id-w4", "id-w3"),
        mk(@w, 5, "id-w5", "id-w4")
      ]

      shuffled = [Enum.at(batch, 2), Enum.at(batch, 0), Enum.at(batch, 1)]
      {existing, present_by_coord, present_by_id} = store_of([@w1, @w2])
      a = MergePlan.plan_merge(batch, existing, present_by_coord, present_by_id)
      b = MergePlan.plan_merge(shuffled, existing, present_by_coord, present_by_id)
      assert b == a

      # Pinned non-trivial shape so both runs can't agree on garbage.
      assert_matches(
        a,
        {:ok,
         %{
           present_count: 0,
           per_writer: [
             %{
               writer_id: @w,
               first_new_seq: 3,
               new_entries: [
                 %{entry_id: "id-w3"},
                 %{entry_id: "id-w4"},
                 %{entry_id: "id-w5"}
               ]
             }
           ]
         }}
      )
    end
  end
end
