defmodule Commonplace.Log.DocumentProfile.Lane.SQLite do
  @moduledoc false

  @behaviour Commonplace.Log.DocumentProfile.Lane

  alias Commonplace.Log.DocumentProfile.Lane
  alias Commonplace.Log.Persistence.SQLiteServer
  alias Commonplace.LogStore.SQLite, as: SQLiteStore
  alias Commonplace.LogStore.SQLite.Server

  @registry Commonplace.LogStore.SQLite.Registry

  @impl true
  def create_log(log_id, _store), do: SQLiteStore.create_log(log_id)

  @impl true
  def restore_log(log_id, entries, capability),
    do: SQLiteStore.restore_log(log_id, entries, capability)

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
         # A `Persistence` module, not a `LogStore`: `handle.adapter` must mean
         # the same kind of thing on both lanes for the adapter-generic helpers
         # (`Frontier.frontier_value/1`, `Frontier.read_through/3`) to be callable
         # from a handle at all.
         adapter: SQLiteServer,
         store: server
       }}
    end
  end

  @impl true
  def writer_id(handle), do: safe_call(fn -> Server.writer_id(handle.store) end)

  @impl true
  def frontier(handle), do: safe_call(fn -> Server.frontier(handle.store) end)

  @impl true
  def read_writer(handle, opts),
    do: safe_call(fn -> Server.read_writer(handle.store, handle.writer_id, opts) end)

  @impl true
  def append_with_epoch(handle, body, created_at, expected_epoch) do
    safe_call(fn -> Server.append(handle.store, body, created_at, expected_epoch) end)
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
