defmodule Commonplace.Log.DocumentProfile do
  @moduledoc """
  Restricted append façade for ordinary, single-lane Documents.

  `create_log/2` explicitly creates a log and durably establishes its writer
  identity before returning. `open_log/2` only opens existing logs. Both return
  an opaque handle that binds the log identity, durable writer identity,
  adapter, and live store owner. Application callers neither supply nor receive
  a writer identity.

  Activation refuses histories that cannot continue on the one durable lane.
  The base `Commonplace.LogStore.SQLite` and `Commonplace.Log.Engine` APIs remain
  multi-writer capable; this restriction exists only at the Document boundary.

  Rekeying is intentionally absent. Recovery that cannot prove exclusive
  continuation must derive a new lineage log instead of adding a lane here.

  The handle reserves its `lease` binding for the fenced lease/epoch introduced
  by the next profile task. Durable operation-id deduplication is not implemented
  yet; `append/3` currently accepts only `:created_at` in its options. A correct
  operation-id implementation must persist both the key and original result so
  retries remain no-ops after process failure.
  """

  alias Commonplace.LogStore.SQLite
  alias Commonplace.LogStore.SQLite.Server

  @registry Commonplace.LogStore.SQLite.Registry

  defmodule Handle do
    @moduledoc false

    @enforce_keys [:log_id, :writer_id, :adapter, :store]
    defstruct [:log_id, :writer_id, :adapter, :store, :retry_context, :lease]

    @type t :: %__MODULE__{
            log_id: String.t(),
            writer_id: String.t(),
            adapter: module(),
            store: GenServer.server(),
            retry_context: term(),
            lease: term()
          }
  end

  defimpl Inspect, for: Handle do
    import Inspect.Algebra

    def inspect(handle, opts) do
      concat([
        "#Commonplace.Log.DocumentProfile.Handle<",
        to_doc(%{log_id: handle.log_id, adapter: handle.adapter}, opts),
        ">"
      ])
    end
  end

  @opaque handle :: Handle.t()
  @type error :: {:error, {atom(), map()}}

  @doc "Explicitly create a Document log and return its single-lane handle."
  @spec create_log(String.t(), keyword()) :: {:ok, handle()} | error()
  def create_log(log_id, opts) when is_binary(log_id) and is_list(opts) do
    with {:ok, adapter} <- adapter(opts),
         :ok <- adapter.create_log(log_id) do
      activate(adapter, log_id)
    end
  end

  @doc "Open an existing single-lane Document log without creating storage."
  @spec open_log(String.t(), keyword()) :: {:ok, handle()} | error()
  def open_log(log_id, opts) when is_binary(log_id) and is_list(opts) do
    with {:ok, adapter} <- adapter(opts),
         {:ok, _frontier} <- adapter.frontier(log_id) do
      activate(adapter, log_id)
    end
  end

  @doc "Append a body on the durable lane bound into `handle`."
  @spec append(handle(), map(), keyword()) :: {:ok, map()} | error()
  def append(%Handle{} = handle, body, opts) when is_map(body) and is_list(opts) do
    with :ok <- validate_append_options(opts),
         {:ok, frontier} <- handle.adapter.frontier(handle.log_id),
         {:ok, writer_id} <- server_writer_id(handle.store),
         :ok <- validate_lane(frontier, handle.writer_id),
         :ok <- validate_bound_writer(writer_id, handle.writer_id),
         {:ok, result} <-
           handle.adapter.append(handle.log_id, handle.writer_id, body, created_at(opts)) do
      {:ok, Map.delete(result, :writer_id)}
    end
  end

  defp activate(adapter, log_id) do
    with {:ok, frontier} <- adapter.frontier(log_id),
         {:ok, server} <- registered_server(log_id),
         {:ok, writer_id} <- server_writer_id(server),
         :ok <- validate_lane(frontier, writer_id) do
      {:ok,
       %Handle{
         log_id: log_id,
         writer_id: writer_id,
         adapter: adapter,
         store: server,
         retry_context: nil,
         lease: nil
       }}
    end
  end

  defp adapter(opts) do
    case Keyword.get(opts, :adapter, SQLite) do
      SQLite -> {:ok, SQLite}
      unsupported -> {:error, {:storage, %{reason: {:unsupported_profile_adapter, unsupported}}}}
    end
  end

  defp registered_server(log_id) do
    case Registry.lookup(@registry, log_id) do
      [{server, _value}] -> {:ok, server}
      [] -> {:error, {:storage, %{reason: :store_owner_unavailable}}}
    end
  end

  defp server_writer_id(server), do: safe_server_call(fn -> Server.writer_id(server) end)

  defp safe_server_call(fun) do
    try do
      case fun.() do
        {:error, _reason} = error -> error
        result when is_binary(result) -> {:ok, result}
        {:ok, _result} = ok -> ok
      end
    catch
      :exit, reason -> {:error, {:storage, %{reason: {:server_exit, reason}}}}
    end
  end

  defp validate_lane(%{writers: []}, _writer_id), do: :ok
  defp validate_lane(%{writers: [%{writer_id: writer_id}]}, writer_id), do: :ok

  defp validate_lane(%{writers: writers}, _writer_id) do
    {:error, {:multiwriter_document_unsupported, %{writer_count: length(writers)}}}
  end

  defp validate_bound_writer(writer_id, writer_id), do: :ok

  defp validate_bound_writer(_current_writer_id, _bound_writer_id) do
    {:error,
     {:multiwriter_document_unsupported,
      %{writer_count: 1, reason: :durable_lane_changed_since_activation}}}
  end

  defp validate_append_options(opts) do
    case Keyword.keys(opts) -- [:created_at] do
      [] -> :ok
      unsupported -> {:error, {:storage, %{reason: {:unsupported_append_options, unsupported}}}}
    end
  end

  defp created_at(opts), do: Keyword.get_lazy(opts, :created_at, &DateTime.utc_now/0)
end
