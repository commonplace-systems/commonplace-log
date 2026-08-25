defmodule Commonplace.Log.DocumentProfile.Lane.SQLite do
  @moduledoc false

  @behaviour Commonplace.Log.DocumentProfile.Lane

  alias Commonplace.Log.DocumentProfile.Lane
  alias Commonplace.LogStore.SQLite, as: SQLiteStore
  alias Commonplace.LogStore.SQLite.Server

  @registry Commonplace.LogStore.SQLite.Registry

  @impl true
  def create_log(log_id, _store), do: SQLiteStore.create_log(log_id)

  @impl true
  def open_log(log_id, _store) do
    case SQLiteStore.frontier(log_id) do
      {:ok, _frontier} -> :ok
      error -> error
    end
  end

  @impl true
  def activate(log_id, _store) do
    with {:ok, frontier} <- SQLiteStore.frontier(log_id),
         {:ok, server} <- registered_server(log_id),
         {:ok, writer_id} <- safe_call(fn -> Server.writer_id(server) end),
         :ok <- Lane.validate_lane(frontier, writer_id),
         {:ok, lease} <- safe_call(fn -> Server.take_lease(server) end) do
      {:ok,
       %{
         log_id: log_id,
         writer_id: writer_id,
         lease: lease,
         adapter: SQLiteStore,
         store: server
       }}
    end
  end

  @impl true
  def writer_id(handle), do: safe_call(fn -> Server.writer_id(handle.store) end)

  @impl true
  def frontier(handle), do: SQLiteStore.frontier(handle.log_id)

  @impl true
  def read_writer(handle, opts),
    do: SQLiteStore.read_writer(handle.log_id, handle.writer_id, opts)

  @impl true
  def append_with_epoch(handle, body, created_at, expected_epoch) do
    SQLiteStore.append_with_epoch(handle.log_id, body, created_at, expected_epoch)
  end

  @impl true
  def merge_with_epoch(handle, entries, expected_epoch) do
    safe_call(fn -> Server.merge_with_epoch(handle.store, entries, expected_epoch) end)
  end

  defp registered_server(log_id) do
    case Registry.lookup(@registry, log_id) do
      [{server, _value}] -> {:ok, server}
      [] -> {:error, {:storage, %{reason: :store_owner_unavailable}}}
    end
  end

  defp safe_call(fun) do
    try do
      case fun.() do
        {:error, _code, _reason} = error -> error
        {:error, _reason} = error -> error
        result when is_binary(result) -> {:ok, result}
        {:ok, _result} = ok -> ok
      end
    catch
      :exit, reason -> {:error, {:storage, %{reason: {:server_exit, reason}}}}
    end
  end
end
