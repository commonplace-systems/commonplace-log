defmodule Commonplace.LogStore.SQLite.Server do
  @moduledoc """
  Owns one open local SQLite log and serializes operations against it.

  The unique `Registry` key prevents two servers for the same `log_id` in one
  BEAM node. A separate `<log_id>.lock.sqlite3` connection holds an exclusive
  SQLite transaction for the server lifetime, preventing another OS process
  from owning that storage lock.

  This process owns only resources: a connection, a lock, and a local writer
  identity. It is not the semantic actor or authority over a Document.
  Authority remains nested Realm → Cell → Document → log handle → persistence;
  putting persistence behind a process does not move authority down that
  chain.
  """

  use GenServer

  alias Commonplace.Log.{Engine, Frontier, UUID}
  alias Commonplace.Log.Persistence.LocalSQLite
  alias Exqlite.Sqlite3

  @registry Commonplace.LogStore.SQLite.Registry

  @enforce_keys [:data_dir, :log_id, :writer_id, :writer_path, :store, :lock_conn]
  defstruct [:data_dir, :log_id, :writer_id, :writer_path, :store, :lock_conn]

  @type server :: GenServer.server()

  @doc false
  def child_spec(opts) do
    %{
      id: {__MODULE__, Keyword.fetch!(opts, :log_id)},
      start: {__MODULE__, :start_link, [opts]},
      restart: :transient,
      type: :worker
    }
  end

  @doc "Start the owner process for `log_id` in `data_dir`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    log_id = Keyword.fetch!(opts, :log_id)

    with :ok <- ensure_registry_started() do
      GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, log_id}})
    end
  end

  @doc "Return the writer identity currently used by the server."
  @spec writer_id(server()) :: String.t()
  def writer_id(server), do: GenServer.call(server, :writer_id)

  @doc "Take and return the next durable writer lease epoch."
  @spec take_lease(server()) :: {:ok, pos_integer()} | {:error, term()}
  def take_lease(server), do: GenServer.call(server, :take_lease)

  @doc "Replace and persist the writer identity used by future appends."
  @spec rekey(server()) :: {:ok, String.t()} | {:error, term()}
  def rekey(server), do: GenServer.call(server, :rekey)

  @doc "Append a body through `Commonplace.Log.Engine` using this server's writer identity."
  @spec append(server(), map(), DateTime.t() | String.t()) ::
          {:ok, map()} | {:error, term()} | {:error, String.t(), String.t()}
  def append(server, body, created_at \\ DateTime.utc_now()) do
    GenServer.call(server, {:append, body, created_at})
  end

  @doc "Append with a lease epoch bound by a Document profile activation."
  @spec append(server(), map(), DateTime.t() | String.t(), non_neg_integer()) ::
          {:ok, map()} | {:error, term()} | {:error, String.t(), String.t()}
  def append(server, body, created_at, expected_epoch) do
    GenServer.call(server, {:append, body, created_at, expected_epoch})
  end

  @doc false
  def create_log(server), do: GenServer.call(server, :create_log)

  @doc false
  def merge(server, entries), do: GenServer.call(server, {:merge, entries})

  @doc false
  def merge_with_epoch(server, entries, expected_epoch),
    do: GenServer.call(server, {:merge_with_epoch, entries, expected_epoch})

  @doc false
  def frontier(server), do: GenServer.call(server, :frontier)

  @doc false
  def frontier_value(server), do: GenServer.call(server, :frontier_value)

  @doc false
  def read_through(server, frontier, opts),
    do: GenServer.call(server, {:read_through, frontier, opts})

  @doc false
  def read_writer(server, writer_id, opts),
    do: GenServer.call(server, {:read_writer, writer_id, opts})

  @doc false
  def tail_local(server, opts), do: GenServer.call(server, {:tail_local, opts})

  @doc "The one log this server owns, so a caller can refuse a mismatched request."
  @spec log_id(server()) :: String.t()
  def log_id(server), do: GenServer.call(server, :log_id)

  @doc false
  def read_set(server, query), do: GenServer.call(server, {:read_set, query})

  @doc false
  def commit(server, plan), do: GenServer.call(server, {:commit, plan})

  @impl true
  def init(opts) do
    data_dir = Keyword.fetch!(opts, :data_dir)
    log_id = Keyword.fetch!(opts, :log_id)
    mode = Keyword.get(opts, :mode, :create)

    case File.mkdir_p(data_dir) do
      :ok ->
        case acquire_lock(data_dir, log_id) do
          {:ok, lock_conn} -> initialize_locked(lock_conn, data_dir, log_id, mode)
          {:error, reason} -> {:stop, reason}
        end

      {:error, reason} ->
        {:stop, {:data_dir_unavailable, reason}}
    end
  end

  @impl true
  def handle_call(:writer_id, _from, state) do
    {:reply, state.writer_id, state}
  end

  def handle_call(:take_lease, _from, state) do
    {:reply, LocalSQLite.take_lease(state.store, state.log_id), state}
  end

  def handle_call(:rekey, _from, state) do
    writer_id = UUID.uuidv7()

    case File.write(state.writer_path, writer_id) do
      :ok -> {:reply, {:ok, writer_id}, %{state | writer_id: writer_id}}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:append, body, created_at}, _from, state) do
    result =
      Engine.append(
        LocalSQLite,
        state.store,
        state.log_id,
        state.writer_id,
        body,
        created_at
      )

    {:reply, result, state}
  end

  def handle_call({:append, body, created_at, expected_epoch}, _from, state) do
    result =
      Engine.append(
        LocalSQLite,
        state.store,
        state.log_id,
        state.writer_id,
        body,
        created_at,
        expected_epoch
      )

    {:reply, result, state}
  end

  def handle_call(:create_log, _from, state) do
    result = LocalSQLite.create_log(state.store, state.log_id, %{format_version: 1})
    {:reply, result, state}
  end

  def handle_call({:merge, entries}, _from, state) do
    result = Engine.merge(LocalSQLite, state.store, state.log_id, entries)
    {:reply, result, state}
  end

  def handle_call({:merge_with_epoch, entries, expected_epoch}, _from, state) do
    result =
      Engine.merge(LocalSQLite, state.store, state.log_id, entries, expected_epoch)

    {:reply, result, state}
  end

  def handle_call(:frontier, _from, state) do
    {:reply, LocalSQLite.frontier(state.store, state.log_id), state}
  end

  def handle_call(:frontier_value, _from, state) do
    {:reply, Frontier.frontier_value(bound_log(state)), state}
  end

  def handle_call({:read_through, frontier, opts}, _from, state) do
    {:reply, Frontier.read_through(bound_log(state), frontier, opts), state}
  end

  def handle_call({:read_writer, writer_id, opts}, _from, state) do
    {:reply, LocalSQLite.read_writer(state.store, state.log_id, writer_id, opts), state}
  end

  def handle_call({:tail_local, opts}, _from, state) do
    {:reply, LocalSQLite.tail_local(state.store, state.log_id, opts), state}
  end

  def handle_call(:log_id, _from, state) do
    {:reply, state.log_id, state}
  end

  def handle_call({:read_set, query}, _from, state) do
    {:reply, LocalSQLite.read_set(state.store, state.log_id, query), state}
  end

  # Serialized like every other write. The plan carries its own expected revision
  # and epoch, which LocalSQLite.commit/2 checks, so routing it here adds the
  # process serialization without weakening the CAS.
  def handle_call({:commit, plan}, _from, state) do
    {:reply, LocalSQLite.commit(state.store, plan), state}
  end

  @impl true
  def terminate(_reason, state) do
    LocalSQLite.close(state.store)
    Sqlite3.execute(state.lock_conn, "ROLLBACK")
    Sqlite3.close(state.lock_conn)
    :ok
  end

  defp ensure_registry_started do
    case Process.whereis(@registry) do
      nil -> start_registry()
      _pid -> :ok
    end
  end

  defp bound_log(state) do
    %{module: LocalSQLite, store: state.store, log_id: state.log_id}
  end

  defp start_registry do
    case Registry.start_link(keys: :unique, name: @registry) do
      {:ok, pid} ->
        Process.unlink(pid)
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        {:error, {:registry_start_failed, reason}}
    end
  end

  defp acquire_lock(data_dir, log_id) do
    lock_path = Path.join(data_dir, log_id <> ".lock.sqlite3")

    case Sqlite3.open(lock_path) do
      {:ok, conn} ->
        case Sqlite3.execute(conn, "BEGIN EXCLUSIVE") do
          :ok ->
            {:ok, conn}

          {:error, reason} ->
            Sqlite3.close(conn)
            {:error, {:lock_unavailable, reason}}
        end

      {:error, reason} ->
        {:error, {:lock_open_failed, reason}}
    end
  end

  defp initialize_locked(lock_conn, data_dir, log_id, mode) do
    case LocalSQLite.open(data_dir, log_id) do
      {:ok, store} -> initialize_store(lock_conn, store, data_dir, log_id, mode)
      {:error, reason} -> stop_after_lock_error(lock_conn, {:data_open_failed, reason})
    end
  end

  defp initialize_store(lock_conn, store, data_dir, log_id, mode) do
    with :ok <- initialize_log(store, log_id, mode),
         writer_path = Path.join(data_dir, log_id <> ".writer"),
         {:ok, writer_id} <- load_writer(writer_path, mode) do
      {:ok,
       %__MODULE__{
         data_dir: data_dir,
         log_id: log_id,
         writer_id: writer_id,
         writer_path: writer_path,
         store: store,
         lock_conn: lock_conn
       }}
    else
      {:error, reason} ->
        LocalSQLite.close(store)
        stop_after_lock_error(lock_conn, {:initialization_failed, reason})
    end
  end

  defp initialize_log(store, log_id, :create),
    do: LocalSQLite.create_log(store, log_id, %{format_version: 1})

  defp initialize_log(store, log_id, :open) do
    case LocalSQLite.frontier(store, log_id) do
      {:ok, _frontier} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp load_writer(writer_path, :create), do: read_or_create_writer(writer_path)
  defp load_writer(writer_path, :open), do: File.read(writer_path)

  defp read_or_create_writer(writer_path) do
    case File.read(writer_path) do
      {:ok, writer_id} ->
        {:ok, writer_id}

      {:error, :enoent} ->
        writer_id = UUID.uuidv7()

        case File.write(writer_path, writer_id) do
          :ok -> {:ok, writer_id}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp stop_after_lock_error(lock_conn, reason) do
    Sqlite3.execute(lock_conn, "ROLLBACK")
    Sqlite3.close(lock_conn)
    {:stop, reason}
  end
end
