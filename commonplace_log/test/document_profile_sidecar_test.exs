defmodule Commonplace.Log.DocumentProfileSidecarTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.{DocumentProfile, Engine, Jcs, UUID}
  alias Commonplace.Log.DocumentProfile.Lane.Sidecar, as: SidecarLane
  alias Commonplace.Log.Persistence.{CloudflareSidecar, CommitPlan}
  alias Commonplace.Log.Test.{InMemoryPersistence, SidecarLoopback}

  @created_at ~U[2026-08-25 12:34:56Z]

  # The clamp SidecarLoopback mirrors from worker/src/realm/http.ts MAX_PAGE_LIMIT.
  @page_clamp 1000

  defmodule StuckCursorLane do
    @moduledoc "Lane double whose /read-writer cursor advances once, then sticks."

    @behaviour Commonplace.Log.DocumentProfile.Lane

    alias Commonplace.Log.Persistence.CloudflareSidecar

    @writer_id "018f2000-0000-7000-8000-00000000000a"
    @tip %{
      writer_id: @writer_id,
      seq: 5,
      entry_id: "018f2000-0000-7000-8000-00000000000b"
    }

    @impl true
    def create_log(_log_id, _store), do: :ok

    @impl true
    def open_log(_log_id, _store), do: :ok

    @impl true
    def activate(log_id, store) do
      {:ok,
       %{
         log_id: log_id,
         writer_id: @writer_id,
         lease: 1,
         adapter: CloudflareSidecar,
         store: store
       }}
    end

    @impl true
    def writer_id(_handle), do: {:ok, @writer_id}

    @impl true
    def frontier(_handle), do: {:ok, %{writers: [@tip]}}

    @impl true
    def read_writer(_handle, _opts) do
      # next_after_seq is 3 no matter what after_seq was asked for: the first
      # page appears to advance (0 -> 3), the second does not (3 -> 3).
      {:ok,
       %{
         entries: [%{canonical_bytes: "{}", writer_seq: 3, operation_id: nil}],
         next_after_seq: 3
       }}
    end

    @impl true
    def append_with_epoch(_handle, _body, _created_at, _epoch), do: {:error, :not_found}

    @impl true
    def merge_with_epoch(_handle, _entries, _epoch), do: {:error, :not_found}
  end

  setup do
    {:ok, base} = InMemoryPersistence.start_link()

    store =
      CloudflareSidecar.new("https://loopback.example",
        transport: SidecarLoopback,
        transport_options: {InMemoryPersistence, base}
      )

    %{base: base, store: store, log_id: UUID.uuidv7()}
  end

  test "a second sidecar activation keeps the writer and fences the first without writing", ctx do
    lane = [lane: {SidecarLane, ctx.store}]
    assert {:ok, first} = DocumentProfile.create_log(ctx.log_id, lane)
    assert {:ok, %{writer_seq: 1}} = DocumentProfile.append(first, %{"n" => 1}, [])
    writer_id = first.writer_id

    assert {:ok, second} = DocumentProfile.open_log(ctx.log_id, lane)
    assert second.writer_id == writer_id
    assert second.lease == first.lease + 1

    assert {:ok, before_frontier} = CloudflareSidecar.frontier(ctx.store, ctx.log_id)

    assert {:error, {:writer_lease_fenced, %{}}} =
             DocumentProfile.append(first, %{"must_not_write" => true}, [])

    assert {:ok, after_frontier} = CloudflareSidecar.frontier(ctx.store, ctx.log_id)
    assert after_frontier == before_frontier

    assert {:ok, %{writer_seq: 2}} = DocumentProfile.append(second, %{"n" => 2}, [])

    assert {:ok, %{writers: [%{writer_id: ^writer_id, seq: 2}]}} =
             CloudflareSidecar.frontier(ctx.store, ctx.log_id)

    assert {:ok, %{entries: entries, next_after_seq: nil}} =
             CloudflareSidecar.read_writer(ctx.store, ctx.log_id, writer_id,
               after_seq: 0,
               limit: 10
             )

    assert Enum.map(entries, & &1.operation_id) == [nil, nil]
  end

  test "re-preparing exact inputs over the sidecar has one byte-identical logical effect", ctx do
    assert {:ok, handle} =
             DocumentProfile.create_log(ctx.log_id, lane: {SidecarLane, ctx.store})

    bodies = [%{"kind" => "commit"}, %{"kind" => "select_head"}]
    opts = [operation_id: "sidecar-exact-retry", created_at: @created_at]

    assert {:ok, first} = DocumentProfile.prepare_append(handle, bodies, opts)
    assert {:ok, %{inserted: 2, present: 0}} = DocumentProfile.commit_prepared(handle, first)
    first_bytes = lane_bytes(ctx.store, ctx.log_id, handle.writer_id)

    assert {:ok, retry} = DocumentProfile.prepare_append(handle, bodies, opts)
    assert {:ok, %{inserted: 0, present: 2}} = DocumentProfile.commit_prepared(handle, retry)
    assert lane_bytes(ctx.store, ctx.log_id, handle.writer_id) == first_bytes
    assert length(first_bytes) == 2

    assert {:ok, %{entries: writer_entries, next_after_seq: nil}} =
             CloudflareSidecar.read_writer(ctx.store, ctx.log_id, handle.writer_id,
               after_seq: 0,
               limit: 100
             )

    assert Enum.map(writer_entries, & &1.operation_id) ==
             ["sidecar-exact-retry", "sidecar-exact-retry"]

    assert {:ok, %{entries: local_entries, next_after_arrival: nil}} =
             CloudflareSidecar.tail_local(ctx.store, ctx.log_id,
               after_arrival: 0,
               limit: 100
             )

    assert Enum.map(local_entries, & &1.operation_id) ==
             ["sidecar-exact-retry", "sidecar-exact-retry"]
  end

  test "sidecar open never creates an unknown log", ctx do
    before = Agent.get(ctx.base, & &1)

    assert {:error, {:log_not_found, %{}}} =
             DocumentProfile.open_log(ctx.log_id, lane: {SidecarLane, ctx.store})

    assert Agent.get(ctx.base, & &1) == before
  end

  test "sidecar activation refuses a genuine multi-lane history", ctx do
    assert :ok = CloudflareSidecar.create_log(ctx.store, ctx.log_id, %{format_version: 1})

    for writer_id <- [UUID.uuidv7(), UUID.uuidv7()] do
      assert {:ok, %{writer_seq: 1}} =
               Engine.append(
                 CloudflareSidecar,
                 ctx.store,
                 ctx.log_id,
                 writer_id,
                 %{"multi_lane" => true},
                 @created_at
               )
    end

    assert {:error, {:multiwriter_document_unsupported, %{writer_count: 2}}} =
             DocumentProfile.open_log(ctx.log_id, lane: {SidecarLane, ctx.store})
  end

  test "prepare pages a lane longer than the provider clamp and appends", ctx do
    lane = [lane: {SidecarLane, ctx.store}]
    assert {:ok, handle} = DocumentProfile.create_log(ctx.log_id, lane)
    seed_lane(ctx.store, ctx.log_id, handle.writer_id, handle.lease, @page_clamp + 1)

    # Positive control on the instrument: the double really clamps — a
    # whole-lane read comes back truncated with a resume cursor.
    assert {:ok, %{entries: clamped, next_after_seq: @page_clamp}} =
             CloudflareSidecar.read_writer(ctx.store, ctx.log_id, handle.writer_id,
               after_seq: 0,
               limit: @page_clamp + 1
             )

    assert length(clamped) == @page_clamp

    opts = [operation_id: "paged-append", created_at: @created_at]

    assert {:ok, %{inserted: 1, present: 0}} =
             DocumentProfile.append_batch(handle, [%{"kind" => "after_clamp"}], opts)

    writer_id = handle.writer_id
    tip_seq = @page_clamp + 2

    assert {:ok, %{writers: [%{writer_id: ^writer_id, seq: ^tip_seq}]}} =
             CloudflareSidecar.frontier(ctx.store, ctx.log_id)

    # Exact retry re-reads the now even longer lane through the same paging
    # and recovers the identical batch — which also proves the accumulated
    # pages preserved lane order, since the candidate scan matches by slice.
    assert {:ok, %{inserted: 0, present: 1}} =
             DocumentProfile.append_batch(handle, [%{"kind" => "after_clamp"}], opts)
  end

  test "a lane exactly at the provider clamp prepares on a single page", ctx do
    lane = [lane: {SidecarLane, ctx.store}]
    assert {:ok, handle} = DocumentProfile.create_log(ctx.log_id, lane)
    seed_lane(ctx.store, ctx.log_id, handle.writer_id, handle.lease, @page_clamp)

    # Control: at exactly the clamp there is no truncation and no cursor.
    assert {:ok, %{entries: entries, next_after_seq: nil}} =
             CloudflareSidecar.read_writer(ctx.store, ctx.log_id, handle.writer_id,
               after_seq: 0,
               limit: @page_clamp
             )

    assert length(entries) == @page_clamp

    assert {:ok, %{inserted: 1, present: 0}} =
             DocumentProfile.append_batch(handle, [%{"kind" => "at_clamp"}],
               operation_id: "single-page-append",
               created_at: @created_at
             )

    writer_id = handle.writer_id
    tip_seq = @page_clamp + 1

    assert {:ok, %{writers: [%{writer_id: ^writer_id, seq: ^tip_seq}]}} =
             CloudflareSidecar.frontier(ctx.store, ctx.log_id)
  end

  test "a non-advancing read-writer cursor fails preparation instead of looping" do
    assert {:ok, handle} = DocumentProfile.create_log(UUID.uuidv7(), lane: {StuckCursorLane, nil})

    assert {:error,
            {:storage,
             %{reason: {:nonadvancing_read_writer_cursor, %{after_seq: 3, next_after_seq: 3}}}}} =
             DocumentProfile.prepare_append(handle, [%{"n" => 1}],
               operation_id: "stuck-cursor",
               created_at: @created_at
             )
  end

  # Seeds `count` chained version-1 entries directly through the persistence
  # boundary (chunked commits), so a long fixture lane does not need `count`
  # individual profile appends.
  defp seed_lane(store, log_id, writer_id, lease, count) do
    {entries, _last_entry_id} =
      Enum.map_reduce(1..count, nil, fn seq, prev_entry_id ->
        entry_id = UUID.uuidv7()

        bytes =
          Jcs.canonicalize(%{
            "version" => 1,
            "log_id" => log_id,
            "entry_id" => entry_id,
            "writer_id" => writer_id,
            "writer_seq" => seq,
            "prev_entry_id" => prev_entry_id,
            "created_at" => "2026-08-25T12:34:56Z",
            "body" => %{"n" => seq}
          })

        {%{
           log_id: log_id,
           entry_id: entry_id,
           writer_id: writer_id,
           writer_seq: seq,
           prev_entry_id: prev_entry_id,
           created_at: "2026-08-25T12:34:56Z",
           canonical_bytes: bytes
         }, entry_id}
      end)

    entries
    |> Enum.chunk_every(100)
    |> Enum.reduce(0, fn chunk, revision ->
      tip = List.last(chunk)

      plan = %CommitPlan{
        log_id: log_id,
        expected_revision: revision,
        expected_epoch: lease,
        insert_entries: chunk,
        put_tips: [%{writer_id: writer_id, seq: tip.writer_seq, entry_id: tip.entry_id}]
      }

      {:ok, new_revision} = CloudflareSidecar.commit(store, plan)
      new_revision
    end)

    :ok
  end

  defp lane_bytes(store, log_id, writer_id) do
    assert {:ok, %{entries: entries, next_after_seq: nil}} =
             CloudflareSidecar.read_writer(store, log_id, writer_id,
               after_seq: 0,
               limit: 100
             )

    Enum.map(entries, & &1.canonical_bytes)
  end
end
