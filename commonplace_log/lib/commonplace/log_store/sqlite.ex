defmodule Commonplace.LogStore.SQLite do
  @moduledoc """
  Durable local implementation of `Commonplace.LogStore`.

  `create_log/1` is the only operation that creates a log. Other operations
  open an existing log: they first look up `log_id` in
  `Commonplace.LogStore.SQLite.Registry`, then require its database and durable
  writer sidecar to exist before starting an open-only
  `Commonplace.LogStore.SQLite.Server`. The server validates the stored log but
  does not run creation logic in that mode. This two-stage check keeps a read of
  an unknown log entirely side-effect free, while registry-first lookup lets a
  read concurrent with an in-process create join the creating server. If it
  arrives before that server is registered, it cleanly linearizes before the
  create and returns `log_not_found` without starting a process or touching the
  directory.

  The server owns the SQLite connection, lock, and local writer identity, and
  serializes every operation. The callback's `writer_id` argument is retained
  for behaviour compatibility; local append deliberately uses the server-owned
  durable identity.

  Configure the shared directory with:

      config :commonplace_log, Commonplace.LogStore.SQLite,
        data_dir: "/var/lib/commonplace-log"

  It defaults to `commonplace_log_data` beneath the current directory.

  Protocol failures always have the shape `{:error, {code, details}}`, where
  `code` is one of the documented protocol atoms and `details` is a map.
  Persistence and process failures use the same stable outer convention but
  carry the non-protocol code `:storage`: `{:error, {:storage, %{reason: term}}}`.
  Thus callers can distinguish a statement about log contents from an I/O or
  SQLite failure by checking the code.
  """

  @behaviour Commonplace.LogStore

  alias Commonplace.Log.Jcs
  alias Commonplace.LogStore.SQLite.Server

  @registry Commonplace.LogStore.SQLite.Registry
  @supervisor Commonplace.LogStore.SQLite.DynamicSupervisor
  @protocol_codes ~w(writer_gap writer_fork entry_id_collision invalid_entry entry_too_large log_mismatch log_not_found)a

  @impl true
  def create_log(log_id), do: dispatch(log_id, :create, &Server.create_log/1)

  @impl true
  def append(log_id, _writer_id, body, created_at) do
    dispatch(log_id, :open, &Server.append(&1, body, created_at))
  end

  @impl true
  def merge(log_id, entries) do
    with {:ok, raw_entries} <- canonicalize_entries(entries) do
      dispatch(log_id, :open, &Server.merge(&1, raw_entries))
    end
    |> normalize()
  end

  @impl true
  def frontier(log_id), do: dispatch(log_id, :open, &Server.frontier/1)

  @impl true
  def read_writer(log_id, writer_id, opts) do
    dispatch(log_id, :open, &Server.read_writer(&1, writer_id, opts))
  end

  @impl true
  def tail_local(log_id, opts), do: dispatch(log_id, :open, &Server.tail_local(&1, opts))

  defp dispatch(log_id, mode, operation) do
    case server_for(log_id, mode) do
      {:ok, server} -> safe_call(fn -> operation.(server) end)
      {:error, reason} -> {:error, reason}
    end
    |> normalize()
  end

  defp server_for(log_id, mode) do
    case Registry.lookup(@registry, log_id) do
      [{server, _value}] ->
        if Process.alive?(server), do: {:ok, server}, else: start_server(log_id, mode)

      [] ->
        start_server(log_id, mode)
    end
  end

  defp start_server(log_id, :open) do
    data_dir = data_dir()

    if existing_log_files?(data_dir, log_id) do
      start_server(log_id, data_dir, :open)
    else
      {:error, :not_found}
    end
  end

  defp start_server(log_id, :create), do: start_server(log_id, data_dir(), :create)

  defp start_server(log_id, data_dir, mode) do
    child = {Server, data_dir: data_dir, log_id: log_id, mode: mode}

    case DynamicSupervisor.start_child(@supervisor, child) do
      {:ok, server} -> {:ok, server}
      {:error, {:already_started, server}} -> {:ok, server}
      {:error, reason} -> {:error, reason}
    end
  end

  defp existing_log_files?(data_dir, log_id) do
    File.regular?(Path.join(data_dir, log_id <> ".sqlite3")) and
      File.regular?(Path.join(data_dir, log_id <> ".writer"))
  end

  defp data_dir do
    :commonplace_log
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:data_dir, Path.expand("commonplace_log_data"))
  end

  defp canonicalize_entries(entries) when is_list(entries) do
    try do
      {:ok,
       Enum.map(entries, fn
         entry when is_map(entry) -> Jcs.canonicalize(entry)
         entry when is_binary(entry) -> entry
         _entry -> :not_entry_bytes
       end)}
    rescue
      ArgumentError -> {:error, {:invalid_entry, %{reason: "not-json-value"}}}
    end
  end

  defp safe_call(fun) do
    try do
      fun.()
    catch
      :exit, reason -> {:error, {:server_exit, reason}}
    end
  end

  defp normalize(:ok), do: :ok
  defp normalize({:ok, _value} = ok), do: ok

  defp normalize({:error, code, reason}) when is_binary(code) do
    protocol_code =
      case code do
        "entry_too_large" -> :entry_too_large
        _validator_code -> :invalid_entry
      end

    {:error, {protocol_code, %{reason: reason}}}
  end

  defp normalize({:error, {:invalid_batch, details}}),
    do: {:error, {:invalid_entry, details_map(details)}}

  defp normalize({:error, {code, details}}) when code in @protocol_codes,
    do: {:error, {code, details_map(details)}}

  defp normalize({:error, code}) when code in @protocol_codes,
    do: {:error, {code, %{}}}

  defp normalize({:error, :not_found}), do: {:error, {:log_not_found, %{}}}

  defp normalize({:error, {:initialization_failed, reason}}) do
    case normalize({:error, reason}) do
      {:error, {code, _details}} = protocol when code in @protocol_codes -> protocol
      _storage -> storage_error({:initialization_failed, reason})
    end
  end

  defp normalize({:error, {:storage, details}}),
    do: {:error, {:storage, details_map(details)}}

  defp normalize({:error, reason}), do: storage_error(reason)
  defp normalize(other), do: other

  defp storage_error(reason), do: {:error, {:storage, %{reason: reason}}}
  defp details_map(details) when is_map(details), do: details
  defp details_map(details), do: %{reason: details}
end
