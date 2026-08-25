defmodule Commonplace.Log.DocumentProfile.Lane.Sidecar do
  @moduledoc false

  @behaviour Commonplace.Log.DocumentProfile.Lane

  alias Commonplace.Log.{DocumentProfile.Lane, Engine}
  alias Commonplace.Log.Persistence.CloudflareSidecar

  @impl true
  def create_log(log_id, %CloudflareSidecar{} = store) do
    CloudflareSidecar.create_log(store, log_id, %{format_version: 1})
  end

  @impl true
  def open_log(log_id, %CloudflareSidecar{} = store) do
    case CloudflareSidecar.frontier(store, log_id) do
      {:ok, _frontier} -> :ok
      error -> error
    end
  end

  @impl true
  def activate(log_id, %CloudflareSidecar{} = store) do
    with {:ok, %{lease_epoch: lease, writer_id: writer_id}} <-
           CloudflareSidecar.take_lease(store, log_id),
         {:ok, frontier} <- CloudflareSidecar.frontier(store, log_id),
         :ok <- Lane.validate_lane(frontier, writer_id) do
      {:ok,
       %{
         log_id: log_id,
         writer_id: writer_id,
         lease: lease,
         adapter: CloudflareSidecar,
         store: store
       }}
    end
  end

  @impl true
  def writer_id(handle) do
    query = %{writers: [], coordinates: [], entry_ids: []}

    case CloudflareSidecar.read_set(handle.store, handle.log_id, query) do
      {:ok, %{document_writer_id: writer_id}} when is_binary(writer_id) -> {:ok, writer_id}
      {:ok, %{document_writer_id: nil}} -> {:error, {:storage, %{reason: :writer_id_unavailable}}}
      error -> error
    end
  end

  @impl true
  def frontier(handle), do: CloudflareSidecar.frontier(handle.store, handle.log_id)

  @impl true
  def read_writer(handle, opts) do
    CloudflareSidecar.read_writer(handle.store, handle.log_id, handle.writer_id, opts)
  end

  @impl true
  def append_with_epoch(handle, body, created_at, expected_epoch) do
    Engine.append(
      CloudflareSidecar,
      handle.store,
      handle.log_id,
      handle.writer_id,
      body,
      created_at,
      expected_epoch
    )
  end

  @impl true
  def merge_with_epoch(handle, entries, expected_epoch) do
    Engine.merge(CloudflareSidecar, handle.store, handle.log_id, entries, expected_epoch)
  end
end
