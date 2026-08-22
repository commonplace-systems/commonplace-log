defmodule Commonplace.Log.AdapterEquivalenceTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.{Engine, Jcs}
  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.Log.Test.InMemoryPersistence

  @log_id "018f0000-0000-7000-8000-000000000001"
  @other_log_id "018f0000-0000-7000-8000-000000000002"
  @writer_id "018f0000-0000-7000-8000-00000000000a"
  @writer_b "018f0000-0000-7000-8000-00000000000b"
  @created_at "2026-08-22T12:34:56Z"

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "commonplace-adapter-equivalence-#{System.unique_integer([:positive])}"
      )

    assert {:ok, sqlite} = LocalSQLite.open(data_dir, @log_id)
    assert :ok = LocalSQLite.create_log(sqlite, @log_id, %{})
    assert {:ok, memory} = InMemoryPersistence.start_link()
    assert :ok = InMemoryPersistence.create_log(memory, @log_id, %{})

    on_exit(fn ->
      LocalSQLite.close(sqlite)
      File.rm_rf!(data_dir)
    end)

    %{sqlite: sqlite, memory: memory}
  end

  test "gap errors are equal", stores do
    entry = entry(2, entry_id(2), entry_id(1))

    assert equal_merge(stores, [entry]) ==
             {:error, {:writer_gap, %{writer_id: @writer_id, expected_seq: 1, tip_entry_id: nil}}}
  end

  test "fork errors are equal", stores do
    original = entry(1, entry_id(1), nil)
    assert equal_merge(stores, [original]) == {:ok, %{inserted: 1, present: 0, revision: 1}}

    fork = entry(1, entry_id(2), nil, %{"fork" => true})

    assert equal_merge(stores, [fork]) ==
             {:error, {:writer_fork, %{writer_id: @writer_id, seq: 1}}}
  end

  test "entry-id reuse with different bytes errors are equal", stores do
    original = entry(1, entry_id(1), nil)
    assert equal_merge(stores, [original]) == {:ok, %{inserted: 1, present: 0, revision: 1}}

    reused_id = entry(2, entry_id(1), entry_id(1), %{"different" => true})

    assert equal_merge(stores, [reused_id]) ==
             {:error, {:entry_id_collision, %{entry_id: entry_id(1)}}}
  end

  test "entry validation errors preserve the same distinctive reason slug", stores do
    invalid =
      entry(1, entry_id(1), nil)
      |> Jason.decode!()
      |> Map.put("entry_id", "malformed-uuid")
      |> Jcs.canonicalize()

    assert equal_merge(stores, [invalid]) ==
             {:error, "invalid_entry", "uuid-malformed"}
  end

  test "wrong-log errors are equal", stores do
    wrong_log = entry(1, entry_id(1), nil, %{}, @other_log_id)

    assert equal_merge(stores, [wrong_log]) ==
             {:error, "invalid_entry", "log-id-mismatch"}
  end

  test "intra-batch predecessor-linkage errors are equal", stores do
    batch = [
      entry(1, entry_id(1), nil),
      entry(2, entry_id(2), entry_id(99))
    ]

    assert equal_merge(stores, batch) ==
             {:error,
              {:invalid_batch,
               %{
                 reason:
                   "writer #{@writer_id} seq 2: prev_entry_id does not name the preceding batch entry"
               }}}
  end

  test "first append has the same semantic result and resulting frontier", stores do
    {sqlite_result, memory_result} =
      append_both(stores, %{"kind" => "first-append"})

    # Engine.append/6 creates a cryptographically random entry_id inside each
    # invocation. It is the sole non-replica-metadata exclusion: compare every
    # other result/frontier field, then bind each generated ID back to its own
    # frontier. Raw adapter rows are intentionally not compared because
    # arrival_seq and received_at_ms are replica-local by contract.
    assert Map.drop(sqlite_result, [:entry_id]) == Map.drop(memory_result, [:entry_id])
    assert sqlite_result.writer_seq == 1
    assert_equal_append_frontiers(stores, sqlite_result, memory_result)
  end

  test "chained append has the same semantic result and resulting frontier", stores do
    first = entry(1, entry_id(1), nil)
    assert equal_merge(stores, [first]) == {:ok, %{inserted: 1, present: 0, revision: 1}}

    {sqlite_result, memory_result} =
      append_both(stores, %{"kind" => "chained-append"})

    # The independently generated entry_id is excluded for the same reason as
    # in the first-append test; arrival_seq and received_at_ms are deliberately
    # absent from these caller-visible comparisons because they are local.
    assert Map.drop(sqlite_result, [:entry_id]) == Map.drop(memory_result, [:entry_id])
    assert sqlite_result.writer_seq == 2
    assert_equal_append_frontiers(stores, sqlite_result, memory_result)
  end

  test "fresh-chain merge has the same result and resulting frontier", stores do
    # Feed writer B first so equality alone cannot conceal a failure to honor
    # the contract's writer_id ordering requirement.
    batch = [entry(1, entry_id(20), nil, %{"writer" => "b"}, @log_id, @writer_b) | chain(3)]

    assert equal_merge(stores, batch) ==
             {:ok, %{inserted: 4, present: 0, revision: 1}}

    assert {:ok, %{writers: writers}} = assert_equal_frontiers(stores)
    assert Enum.map(writers, & &1.writer_id) == [@writer_id, @writer_b]
  end

  test "idempotent re-merge has the same result and resulting frontier", stores do
    batch = chain(3)
    assert equal_merge(stores, batch) == {:ok, %{inserted: 3, present: 0, revision: 1}}

    assert equal_merge(stores, batch) ==
             {:ok, %{inserted: 0, present: 3, revision: 1}}

    assert_equal_frontiers(stores)
  end

  test "writer-range pages and cursors are equal and reassemble to the unpaged read", stores do
    batch = chain(5)
    assert equal_merge(stores, batch) == {:ok, %{inserted: 5, present: 0, revision: 1}}

    sqlite_pages = writer_pages(LocalSQLite, stores.sqlite, 2)
    memory_pages = writer_pages(InMemoryPersistence, stores.memory, 2)

    assert sqlite_pages == memory_pages
    assert Enum.map(sqlite_pages, & &1.next_after_seq) == [2, 4, nil]

    assert {:ok, sqlite_unpaged} =
             read_writer(LocalSQLite, stores.sqlite, after_seq: 0, limit: 10)

    assert {:ok, memory_unpaged} =
             read_writer(InMemoryPersistence, stores.memory, after_seq: 0, limit: 10)

    assert sqlite_unpaged == memory_unpaged
    assert sqlite_unpaged.next_after_seq == nil
    assert Enum.flat_map(sqlite_pages, & &1.entries) == sqlite_unpaged.entries
  end

  defp equal_merge(stores, entries) do
    sqlite_result = Engine.merge(LocalSQLite, stores.sqlite, @log_id, entries)
    memory_result = Engine.merge(InMemoryPersistence, stores.memory, @log_id, entries)
    assert sqlite_result == memory_result
    sqlite_result
  end

  defp append_both(stores, body) do
    sqlite_result =
      Engine.append(LocalSQLite, stores.sqlite, @log_id, @writer_id, body, @created_at)

    memory_result =
      Engine.append(InMemoryPersistence, stores.memory, @log_id, @writer_id, body, @created_at)

    assert {:ok, sqlite_result} = sqlite_result
    assert {:ok, memory_result} = memory_result
    {sqlite_result, memory_result}
  end

  defp assert_equal_append_frontiers(stores, sqlite_result, memory_result) do
    assert {:ok, %{writers: [sqlite_tip]}} = LocalSQLite.frontier(stores.sqlite, @log_id)

    assert {:ok, %{writers: [memory_tip]}} =
             InMemoryPersistence.frontier(stores.memory, @log_id)

    assert sqlite_tip.entry_id == sqlite_result.entry_id
    assert memory_tip.entry_id == memory_result.entry_id
    assert Map.drop(sqlite_tip, [:entry_id]) == Map.drop(memory_tip, [:entry_id])
  end

  defp assert_equal_frontiers(stores) do
    sqlite_frontier = LocalSQLite.frontier(stores.sqlite, @log_id)
    memory_frontier = InMemoryPersistence.frontier(stores.memory, @log_id)
    assert sqlite_frontier == memory_frontier
    sqlite_frontier
  end

  defp writer_pages(module, store, limit, after_seq \\ 0, pages \\ []) do
    assert {:ok, page} = read_writer(module, store, after_seq: after_seq, limit: limit)
    pages = pages ++ [page]

    case page.next_after_seq do
      nil -> pages
      cursor -> writer_pages(module, store, limit, cursor, pages)
    end
  end

  defp read_writer(module, store, opts) do
    module.read_writer(store, @log_id, @writer_id,
      after_seq: Keyword.fetch!(opts, :after_seq),
      through_seq: 5,
      limit: Keyword.fetch!(opts, :limit)
    )
  end

  defp chain(count) do
    {entries, _last_id} =
      Enum.map_reduce(1..count, nil, fn seq, previous_id ->
        id = entry_id(seq)
        {entry(seq, id, previous_id, %{"n" => seq}), id}
      end)

    entries
  end

  defp entry(
         seq,
         id,
         previous_id,
         body \\ %{},
         log_id \\ @log_id,
         writer_id \\ @writer_id
       ) do
    Jcs.canonicalize(%{
      "version" => 1,
      "log_id" => log_id,
      "entry_id" => id,
      "writer_id" => writer_id,
      "writer_seq" => seq,
      "prev_entry_id" => previous_id,
      "created_at" => @created_at,
      "body" => body
    })
  end

  defp entry_id(number) do
    "018f0000-0000-7000-8000-" <> String.pad_leading(Integer.to_string(number), 12, "0")
  end
end
