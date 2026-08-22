defmodule Commonplace.Log.EngineTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.{Engine, Entry, Jcs, UUID}

  alias Commonplace.Log.Test.{
    CommitErrorPersistence,
    InMemoryPersistence,
    StaleThenDelegatePersistence
  }

  @log_id "018f5e2a-8b3c-7d4e-9f10-123456789abc"
  @writer_a "018f5e2a-8b3c-7d4e-9f10-123456789abd"
  @writer_b "018f5e2a-8b3c-7d4e-9f10-123456789abe"
  @created_at ~U[2026-08-22 12:34:56Z]

  setup do
    start_supervised!({Agent, fn -> %{logs: %{}} end})
    |> then(fn store ->
      assert :ok = InMemoryPersistence.create_log(store, @log_id, %{})
      %{store: store}
    end)
  end

  test "uuidv7 embeds a known 48-bit millisecond timestamp and sets layout bits" do
    uuid = UUID.uuidv7(0x0123456789AB)
    assert "01234567-89ab-7" <> _ = uuid
    assert <<_::binary-size(19), variant, _::binary>> = uuid
    assert variant in [?8, ?9, ?a, ?b]
    assert uuid == String.downcase(uuid)
  end

  test "append at seq 1 stores independently validated canonical bytes", %{store: store} do
    assert {:ok, result} =
             Engine.append(
               InMemoryPersistence,
               store,
               @log_id,
               @writer_a,
               %{"kind" => "note"},
               @created_at
             )

    assert result.writer_seq == 1

    expected = %{
      "version" => 1,
      "log_id" => @log_id,
      "entry_id" => result.entry_id,
      "writer_id" => @writer_a,
      "writer_seq" => 1,
      "prev_entry_id" => nil,
      "created_at" => "2026-08-22T12:34:56Z",
      "body" => %{"kind" => "note"}
    }

    assert {:ok, expected_bytes} = expected |> Jcs.canonicalize() |> Entry.validate_entry()
    stored = InMemoryPersistence.snapshot(store, @log_id).entries[{@writer_a, 1}]
    assert stored.canonical_bytes == expected_bytes
    refute Map.has_key?(result, :canonical_bytes)
  end

  test "three appends form a 1,2,3 predecessor chain", %{store: store} do
    results = for n <- 1..3, do: append!(store, @writer_a, %{"n" => n})
    assert Enum.map(results, & &1.writer_seq) == [1, 2, 3]

    entries = stored_entries(store, @writer_a)

    assert Enum.map(entries, & &1["prev_entry_id"]) == [
             nil,
             results |> Enum.at(0) |> Map.fetch!(:entry_id),
             results |> Enum.at(1) |> Map.fetch!(:entry_id)
           ]
  end

  test "two writers allocate independent sequences", %{store: store} do
    assert %{writer_seq: 1} = append!(store, @writer_a, %{"a" => 1})
    assert %{writer_seq: 1} = append!(store, @writer_b, %{"b" => 1})
    assert %{writer_seq: 2} = append!(store, @writer_a, %{"a" => 2})
  end

  test "merge inserts a fresh chain and an identical re-merge is all present", %{store: store} do
    batch = chain(@writer_a, 3)

    assert {:ok, %{inserted: 3, present: 0}} =
             Engine.merge(InMemoryPersistence, store, @log_id, batch)

    assert {:ok, %{inserted: 0, present: 3} = result} =
             Engine.merge(InMemoryPersistence, store, @log_id, batch)

    assert result.inserted + result.present == length(batch)
  end

  test "a gap is a domain error and stores nothing", %{store: store} do
    [entry] = chain(@writer_a, 1, start_seq: 2, prev: UUID.uuidv7(1))

    assert {:error, {:writer_gap, %{expected_seq: 1}}} =
             Engine.merge(InMemoryPersistence, store, @log_id, [entry])

    assert InMemoryPersistence.snapshot(store, @log_id).entries == %{}
  end

  test "an occupied-coordinate fork preserves original canonical bytes", %{store: store} do
    [original] = chain(@writer_a, 1)
    assert {:ok, _} = Engine.merge(InMemoryPersistence, store, @log_id, [original])
    before = InMemoryPersistence.snapshot(store, @log_id).entries[{@writer_a, 1}].canonical_bytes
    [fork] = chain(@writer_a, 1, body: %{"fork" => true})

    assert {:error, {:writer_fork, %{writer_id: @writer_a, seq: 1}}} =
             Engine.merge(InMemoryPersistence, store, @log_id, [fork])

    assert InMemoryPersistence.snapshot(store, @log_id).entries[{@writer_a, 1}].canonical_bytes ==
             before
  end

  test "an entry for another log is rejected without storage", %{store: store} do
    [entry] = chain(@writer_a, 1, log_id: UUID.uuidv7(2))

    assert {:error, "invalid_entry", "log-id-mismatch"} =
             Engine.merge(InMemoryPersistence, store, @log_id, [entry])

    assert InMemoryPersistence.snapshot(store, @log_id).entries == %{}
  end

  test "an invalid entry preserves Entry's reason slug and stores nothing", %{store: store} do
    [valid_raw] = chain(@writer_a, 1)

    raw =
      valid_raw
      |> Jason.decode!()
      |> Map.put("entry_id", "malformed-uuid")
      |> Jcs.canonicalize()

    assert {:error, "invalid_entry", slug} =
             Engine.merge(InMemoryPersistence, store, @log_id, [raw])

    assert slug == "uuid-malformed"
    assert InMemoryPersistence.snapshot(store, @log_id).entries == %{}
  end

  test "append and merge each retry three stale commits and succeed on the fourth", %{store: base} do
    {:ok, append_store} = StaleThenDelegatePersistence.start_link(base, 3)

    assert {:ok, %{writer_seq: 1}} =
             Engine.append(
               StaleThenDelegatePersistence,
               append_store,
               @log_id,
               @writer_a,
               %{},
               @created_at
             )

    assert StaleThenDelegatePersistence.commit_calls(append_store) == 4

    {:ok, merge_base} = InMemoryPersistence.start_link()
    :ok = InMemoryPersistence.create_log(merge_base, @log_id, %{})
    {:ok, merge_store} = StaleThenDelegatePersistence.start_link(merge_base, 3)

    assert {:ok, %{inserted: 2}} =
             Engine.merge(StaleThenDelegatePersistence, merge_store, @log_id, chain(@writer_b, 2))

    assert StaleThenDelegatePersistence.commit_calls(merge_store) == 4
  end

  test "retry exhaustion is typed and stores nothing", %{store: base} do
    {:ok, store} = StaleThenDelegatePersistence.start_link(base, Engine.max_stale_retries() + 1)

    assert {:error, {:retry_exhausted, %{operation: :append, attempts: 4}}} =
             Engine.append(
               StaleThenDelegatePersistence,
               store,
               @log_id,
               @writer_a,
               %{},
               @created_at
             )

    assert StaleThenDelegatePersistence.commit_calls(store) == 4
    assert InMemoryPersistence.snapshot(base, @log_id).entries == %{}
  end

  test "non-stale commit storage errors surface unchanged", %{store: base} do
    error = {:disk_full, %{path: "test"}}

    assert {:error, ^error} =
             Engine.append(
               CommitErrorPersistence,
               {base, error},
               @log_id,
               @writer_a,
               %{},
               @created_at
             )

    assert InMemoryPersistence.snapshot(base, @log_id).entries == %{}
  end

  defp append!(store, writer, body) do
    assert {:ok, result} =
             Engine.append(InMemoryPersistence, store, @log_id, writer, body, @created_at)

    result
  end

  defp stored_entries(store, writer) do
    store
    |> InMemoryPersistence.snapshot(@log_id)
    |> Map.fetch!(:entries)
    |> Enum.filter(fn {{candidate, _seq}, _row} -> candidate == writer end)
    |> Enum.sort_by(fn {{_writer, seq}, _row} -> seq end)
    |> Enum.map(fn {_coord, row} -> Jason.decode!(row.canonical_bytes) end)
  end

  defp chain(writer, count, opts \\ []) do
    log_id = Keyword.get(opts, :log_id, @log_id)
    start_seq = Keyword.get(opts, :start_seq, 1)
    first_prev = Keyword.get(opts, :prev, nil)
    body = Keyword.get(opts, :body, %{})

    {entries, _prev} =
      Enum.map_reduce(start_seq..(start_seq + count - 1), first_prev, fn seq, prev ->
        id = UUID.uuidv7(1_700_000_000_000 + seq)

        entry = %{
          "version" => 1,
          "log_id" => log_id,
          "entry_id" => id,
          "writer_id" => writer,
          "writer_seq" => seq,
          "prev_entry_id" => prev,
          "created_at" => "2026-08-22T12:34:56Z",
          "body" => body
        }

        {Jcs.canonicalize(entry), id}
      end)

    entries
  end
end
