defmodule Commonplace.Log.DocumentProfileSidecarTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.{DocumentProfile, Engine, UUID}
  alias Commonplace.Log.DocumentProfile.Lane.Sidecar, as: SidecarLane
  alias Commonplace.Log.Persistence.CloudflareSidecar
  alias Commonplace.Log.Test.{InMemoryPersistence, SidecarLoopback}

  @created_at ~U[2026-08-25 12:34:56Z]

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

  defp lane_bytes(store, log_id, writer_id) do
    assert {:ok, %{entries: entries, next_after_seq: nil}} =
             CloudflareSidecar.read_writer(store, log_id, writer_id,
               after_seq: 0,
               limit: 100
             )

    Enum.map(entries, & &1.canonical_bytes)
  end
end
