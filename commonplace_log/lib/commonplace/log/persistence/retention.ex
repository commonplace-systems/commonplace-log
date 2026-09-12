defmodule Commonplace.Log.Persistence.Retention do
  @moduledoc """
  Retention capability owned by a persistence adapter.

  Local SQLite exposes an append-only capability: entries have immutable
  update/delete triggers and the adapter has no pruning operation. This
  module verifies a caller's exact closure against that capability. It does
  not create a TTL, pin table, or pretend that `release/1` deletes data.
  """

  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.Log.Persistence.SQLiteServer
  alias Commonplace.Log.Persistence.CloudflareSidecar
  alias Commonplace.LogStore.SQLite.Server

  defmodule Capability do
    @type t :: %__MODULE__{
            adapter: module(),
            mode: :append_only,
            durable_across_restart?: true,
            deletion: :unsupported
          }
    @enforce_keys [:adapter, :mode, :durable_across_restart?, :deletion]
    defstruct [:adapter, :mode, :durable_across_restart?, :deletion]
  end

  defmodule Lease do
    @type t :: %__MODULE__{
            capability: Capability.t(),
            closure: term(),
            status: :retained | :released,
            released_at: integer() | nil
          }
    @enforce_keys [:capability, :closure, :status]
    defstruct [:capability, :closure, :status, :released_at]
  end

  @type verifier :: (term() -> {:ok, term()} | {:error, term()})

  @doc "Returns the capability actually supported by the local SQLite owner."
  @spec capability(LocalSQLite.t()) :: {:ok, Capability.t()} | {:error, term()}
  def capability(%LocalSQLite{}) do
    {:ok,
     %Capability{
       adapter: LocalSQLite,
       mode: :append_only,
       durable_across_restart?: true,
       deletion: :unsupported
     }}
  end

  def capability(other) when not is_struct(other), do: {:error, :unsupported_retention_backend}

  def capability(%CloudflareSidecar{}) do
    {:ok,
     %Capability{
       adapter: CloudflareSidecar,
       mode: :append_only,
       durable_across_restart?: true,
       deletion: :unsupported
     }}
  end

  @doc "Returns the append-only capability for a bound Sidecar owner."
  @spec capability(CloudflareSidecar, CloudflareSidecar.t()) :: {:ok, Capability.t()}
  def capability(CloudflareSidecar, %CloudflareSidecar{}), do: capability(%CloudflareSidecar{})

  def capability(_adapter, _store), do: {:error, :unsupported_retention_backend}

  @doc "Returns the same capability for the production serialized SQLiteServer owner."
  @spec capability(SQLiteServer, GenServer.server()) :: {:ok, Capability.t()} | {:error, term()}
  def capability(SQLiteServer, server) do
    case Server.log_id(server) do
      log_id when is_binary(log_id) ->
        {:ok,
         %Capability{
           adapter: SQLiteServer,
           mode: :append_only,
           durable_across_restart?: true,
           deletion: :unsupported
         }}

      _ ->
        {:error, :unsupported_retention_backend}
    end
  catch
    :exit, _ -> {:error, :unsupported_retention_backend}
  end

  @doc "Verifies and records an exact closure using a bound adapter owner."
  @spec retain(module(), term(), verifier()) :: {:ok, Lease.t()} | {:error, term()}
  def retain(adapter, store, verifier) when is_atom(adapter) and is_function(verifier, 1) do
    with {:ok, policy} <- capability(adapter, store),
         {:ok, closure} <- verifier.(store) do
      {:ok, %Lease{capability: policy, closure: closure, status: :retained}}
    end
  end

  def retain(_adapter, _store, _verifier), do: {:error, :invalid_retention_verifier}

  @doc "Verifies and records an exact closure using the adapter capability."
  @spec retain(LocalSQLite.t(), verifier()) :: {:ok, Lease.t()} | {:error, term()}
  def retain(store, verifier) when is_function(verifier, 1) do
    with {:ok, policy} <- capability(store), {:ok, closure} <- verifier.(store) do
      {:ok, %Lease{capability: policy, closure: closure, status: :retained}}
    end
  end

  def retain(_store, _verifier), do: {:error, :invalid_retention_verifier}

  @doc "Re-verifies the closure against a reopened adapter handle."
  @spec renew(Lease.t(), LocalSQLite.t(), verifier()) :: {:ok, Lease.t()} | {:error, term()}
  def renew(%Lease{status: :retained, capability: expected} = lease, store, verifier)
      when is_function(verifier, 1) do
    with {:ok, actual} <- capability(store),
         true <- actual == expected,
         {:ok, closure} <- verifier.(store),
         true <- closure == lease.closure do
      {:ok, %{lease | closure: closure}}
    else
      false -> {:error, :retention_capability_or_closure_changed}
      error -> error
    end
  end

  def renew(%Lease{status: :released}, _store, _verifier), do: {:error, :lease_released}
  def renew(_lease, _store, _verifier), do: {:error, :invalid_retention_lease}

  @doc "Releases the caller's claim; append-only rows remain durable."
  @spec release(Lease.t()) :: {:ok, Lease.t()} | {:error, term()}
  def release(%Lease{status: :retained} = lease),
    do: {:ok, %{lease | status: :released, released_at: System.system_time(:second)}}

  def release(%Lease{status: :released} = lease), do: {:ok, lease}
  def release(_), do: {:error, :invalid_retention_lease}
end
