defmodule Commonplace.Log.RealmNode.DocumentHandles do
  @moduledoc false

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(log_id, handle), do: Agent.update(__MODULE__, &Map.put(&1, log_id, handle))
  def fetch(log_id), do: Agent.get(__MODULE__, &Map.fetch(&1, log_id))
  def delete(log_id), do: Agent.update(__MODULE__, &Map.delete(&1, log_id))
  def clear, do: Agent.update(__MODULE__, fn _handles -> %{} end)
end

defmodule Commonplace.Log.RealmNode.DocumentAppendQueue do
  @moduledoc """
  Per-document append serializer for the realm node.

  Without it, two concurrent appends to one document both prepare at the same
  coordinate and the loser's commit reports `writer_fork` — the spec's
  halt-everything corruption code — for an ordinary write race. Serializing
  prepare→commit per document makes both succeed at consecutive coordinates,
  so `writer_fork` keeps meaning "history forked", never "you raced a peer".

  Shape: one GenServer per document id, started on demand under a
  `DynamicSupervisor` and registered by id in a unique `Registry`. Appends to
  the same document queue in that server's mailbox; appends to different
  documents run in unrelated servers and never serialize against each other.

  The append closure executes inside the serializer process, so there is no
  lock for a crashed caller to leak: a crash in the closure is caught in the
  serializer, re-raised in the caller, and the next queued append proceeds.
  If the serializer itself is killed mid-append, queued callers get a
  retryable error and the next append restarts it on demand (`:temporary`
  restart — nothing waits on a manual release).

  The wait is bounded by the `GenServer.call` timeout. A timed-out request's
  closure is additionally skipped by a deadline check when it is finally
  dequeued, so an append answered `retryable` is (up to the unavoidable
  in-flight window) not also committed behind the caller's back.
  """

  use GenServer

  @registry __MODULE__.Registry
  @supervisor __MODULE__.Supervisor
  @default_timeout_ms 15_000

  @doc "Children the application supervisor must run for on-demand serializers."
  def child_specs do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor}
    ]
  end

  @doc """
  Run `fun` serialized with every other append to `log_id`.

  Returns `{:ok, fun.()}`, or `{:error, :append_queue_timeout}` when the wait
  exceeded the bound, or `{:error, :append_queue_unavailable}` when the
  serializer died mid-call. An exception raised by `fun` is re-raised here.
  """
  def run(log_id, fun, timeout \\ nil) when is_binary(log_id) and is_function(fun, 0) do
    do_run(log_id, fun, timeout || configured_timeout_ms(), _attempts_left = 2)
  end

  defp do_run(log_id, fun, timeout, attempts_left) do
    server = server(log_id)
    deadline = System.monotonic_time(:millisecond) + timeout

    case GenServer.call(server, {:run, fun, deadline}, timeout) do
      {:returned, value} -> {:ok, value}
      {:caught, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
      :expired -> {:error, :append_queue_timeout}
    end
  catch
    :exit, {:timeout, {GenServer, :call, _args}} ->
      {:error, :append_queue_timeout}

    # A stale Registry entry from a serializer that died before the call was
    # sent: start a fresh one and retry, boundedly.
    :exit, {:noproc, {GenServer, :call, _args}} when attempts_left > 0 ->
      do_run(log_id, fun, timeout, attempts_left - 1)

    :exit, {_reason, {GenServer, :call, _args}} ->
      {:error, :append_queue_unavailable}
  end

  defp server(log_id) do
    case Registry.lookup(@registry, log_id) do
      [{pid, _value}] ->
        pid

      [] ->
        spec = %{
          id: {__MODULE__, log_id},
          start: {__MODULE__, :start_link, [log_id]},
          restart: :temporary
        }

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end
    end
  end

  def start_link(log_id) do
    GenServer.start_link(__MODULE__, :ok, name: {:via, Registry, {@registry, log_id}})
  end

  @impl true
  def init(:ok), do: {:ok, nil}

  @impl true
  def handle_call({:run, fun, deadline}, _from, state) do
    if System.monotonic_time(:millisecond) >= deadline do
      # The caller has already given up (or is about to): do not run work
      # nobody will acknowledge. OTP drops the late reply if the caller is gone.
      {:reply, :expired, state}
    else
      result =
        try do
          {:returned, fun.()}
        catch
          kind, reason -> {:caught, kind, reason, __STACKTRACE__}
        end

      {:reply, result, state}
    end
  end

  defp configured_timeout_ms do
    Application.get_env(:commonplace_log, __MODULE__, [])
    |> Keyword.get(:timeout_ms, @default_timeout_ms)
  end
end
