defmodule Commonplace.Log.Persistence.SQLiteServer do
  @moduledoc """
  `Commonplace.Log.Persistence` over a running `Commonplace.LogStore.SQLite.Server`.

  WHY THIS EXISTS. `DocumentProfile.Handle` carries ONE `:adapter` field, and the
  two lanes filled it with modules of two DIFFERENT behaviours:
  `Lane.Sidecar` published a `Persistence` adapter (`CloudflareSidecar`), while
  `Lane.SQLite` published a `LogStore` (`Commonplace.LogStore.SQLite`, whose
  `frontier/1` and `tail_local/2` are log-id-first and which has no `read_set` at
  all). A caller holding a handle therefore could not use the adapter-generic
  helpers: `Frontier.frontier_value/1` and `Frontier.read_through/3` both call
  `module.frontier(store, log_id)` at ARITY 2. commonplace-doc's DocHost adapter
  reads `Commonplace.LogStore.SQLite` directly for exactly that reason, which is
  the §14 coupling this module exists to remove.

  ⛔ THE STORE HANDLE IS THE SERVER, NEVER THE SERVER'S `%LocalSQLite{}`. That
  struct holds an open connection whose access the GenServer serializes, beside a
  `lock_conn` and the writer identity. Publishing it would let callers bypass that
  serialization and the storage lock. Every call here routes THROUGH the server.

  ## Log binding, and why every callback still checks `log_id`

  A server owns exactly one log for its lifetime and cannot be started without it
  (`Server.init/1` creates or opens the log before the process exists). The
  underlying `LocalSQLite` therefore already answers about that one log no matter
  what `log_id` a caller passes, so a mismatched argument would otherwise be
  ANSWERED rather than refused — the caller would receive another log's data with
  no error. Each callback checks the argument against `Server.log_id/1` and
  refuses with `{:error, :log_mismatch}`, the same term `LocalSQLite` uses.

  ## Two contract shapes this adapter cannot present

    * `{:error, :not_found}` for reads of an uncreated log. A live server implies
      an existing log, so the "store open, log absent" state is unreachable here
      BY CONSTRUCTION rather than by omission.
    * `create_log/3` ignores its `metadata`. `Server.create_log/1` commits
      `%{format_version: 1}`, matching how the server creates the log at init.
  """

  @behaviour Commonplace.Log.Persistence

  alias Commonplace.Log.Persistence.CommitPlan
  alias Commonplace.LogStore.SQLite.Server

  @typedoc "The store handle: a running log-owner server."
  @type t :: GenServer.server()

  @impl true
  def create_log(server, log_id, _metadata) do
    bound(server, log_id, fn -> Server.create_log(server) end)
  end

  @impl true
  def take_lease(server, log_id) do
    bound(server, log_id, fn -> Server.take_lease(server) end)
  end

  @impl true
  def read_set(server, log_id, query) do
    bound(server, log_id, fn -> Server.read_set(server, query) end)
  end

  @impl true
  def commit(server, %CommitPlan{} = plan) do
    bound(server, plan.log_id, fn -> Server.commit(server, plan) end)
  end

  @impl true
  def frontier(server, log_id) do
    bound(server, log_id, fn -> Server.frontier(server) end)
  end

  @impl true
  def read_writer(server, log_id, writer_id, options) do
    bound(server, log_id, fn -> Server.read_writer(server, writer_id, options) end)
  end

  @impl true
  def tail_local(server, log_id, options) do
    bound(server, log_id, fn -> Server.tail_local(server, options) end)
  end

  # The one boundary: a call reaches the server only for the log that server owns.
  defp bound(server, log_id, operation) do
    case Server.log_id(server) do
      ^log_id -> operation.()
      other when is_binary(other) -> {:error, :log_mismatch}
    end
  end
end
