defmodule Commonplace.Log.Sync do
  @moduledoc """
  Replica synchronization from specification section 10. It converges physical
  copies of the same logical log, identified by one `log_id`.

  This is a persistence protocol, not Document or Cell synchronization. It
  must never decide whether an application edit is authorized; accept or
  reject offline work; translate CRDT/Yjs updates or cross a Yepoch boundary;
  merge branches; create lineage; or invoke Document verbs as a side effect of
  receiving bytes. Those semantic admission operations live in Document/Cell
  sync verbs. A branch or mirror derives a new log with explicit lineage; its
  entries must not be fed into this module as though it were another replica.

  Raw replica synchronization belongs on trusted internal storage links.
  Externally held editor capabilities operate on Document/Cell APIs, not on
  persistence merge. Raw merge remains scoped to physical replicas of the
  same logical log identity: source writer IDs and coordinates never become
  destination writer authority. Cross-Document transfer admits semantic
  material and authors destination-native entries instead.

  A replica reference is the deliberately small map
  `%{module: capability_module, store: adapter_handle}`. The capability
  module implements `Commonplace.Log.Sync.Adapter`: frontier reads, paged
  writer-range reads, and canonical-byte merges. The handle is opaque to
  this module. An HTTP-backed adapter can therefore use the same reference
  shape as an in-process persistence adapter without exposing transport or
  storage details here.

  `persistence_replica/2` adapts the existing persistence modules by routing
  merges through `Commonplace.Log.Engine`. A remote adapter may instead be
  referenced directly with `replica/2`.

  Both `pull/4` and `sync/4` return `{:ok, report}` for protocol outcomes.
  `report.outcome` is one of `:converged`, `:deadline`, `:forks`, or
  `:deadline_with_forks`; the accompanying booleans, counters, and fork
  details make combined outcomes explicit. Adapter and malformed-range
  failures return `{:error, reason}`.
  """

  alias Commonplace.Log.Engine

  defmodule Adapter do
    @moduledoc "The three transport-neutral capabilities required of a replica reference."

    @type store :: term()
    @type page :: %{
            entries: [%{canonical_bytes: binary(), writer_seq: pos_integer()}],
            next_after_seq: pos_integer() | nil
          }

    @callback frontier(store(), log_id :: String.t()) ::
                {:ok, %{writers: [map()]}} | {:error, term()}

    @callback read_writer(store(), log_id :: String.t(), writer_id :: String.t(), keyword()) ::
                {:ok, page()} | {:error, term()}

    @doc """
    Merge a page received from a physical replica of the same `log_id`.

    Do not pass entries from a branch, mirror, offline edit, or other Document
    here. This callback performs raw persistence merge: it neither authorizes
    application edits nor creates lineage. Use Document/Cell sync verbs for
    semantic admission into a destination Document.
    """
    @callback merge(store(), log_id :: String.t(), canonical_entries :: [binary()]) ::
                {:ok, map()} | {:error, term()}
  end

  defmodule PersistenceReplica do
    @moduledoc "Adapts an Engine persistence module to the synchronization capability boundary."

    @behaviour Adapter

    @impl true
    def frontier(%{module: module, store: store}, log_id), do: module.frontier(store, log_id)

    @impl true
    def read_writer(%{module: module, store: store}, log_id, writer_id, opts) do
      module.read_writer(store, log_id, writer_id, opts)
    end

    @impl true
    def merge(%{module: module, store: store}, log_id, canonical_entries) do
      Engine.merge(module, store, log_id, canonical_entries)
    end
  end

  @typedoc "A transport-neutral replica reference naming a capability module and opaque handle."
  @type replica :: %{required(:module) => module(), required(:store) => term()}

  @typedoc "A frontier tip. Sequence zero is represented internally with a nil entry ID."
  @type tip :: %{writer_id: String.t(), seq: non_neg_integer(), entry_id: String.t() | nil}

  @typedoc "Actionable fork detail, oriented from the receiving replica to the sending replica."
  @type fork :: %{writer_id: String.t(), local_tip: tip(), remote_tip: tip()}

  @typedoc "Synchronization outcome and measured work."
  @type report :: %{
          outcome: :converged | :deadline | :forks | :deadline_with_forks,
          converged?: boolean(),
          progress?: boolean(),
          deadline_reached?: boolean(),
          inserted: non_neg_integer(),
          present: non_neg_integer(),
          pages: non_neg_integer(),
          passes: non_neg_integer(),
          forks: [fork()]
        }

  @default_page_size 100

  @doc "Build a direct replica reference for a module implementing `Adapter`."
  @spec replica(module(), term()) :: replica()
  def replica(module, store) when is_atom(module), do: %{module: module, store: store}

  @doc "Build a replica reference backed by an Engine persistence module and store handle."
  @spec persistence_replica(module(), term()) :: replica()
  def persistence_replica(module, store) when is_atom(module) do
    replica(PersistenceReplica, %{module: module, store: store})
  end

  @doc """
  Pull all compatible writer suffixes through the remote's snapshot frontier.

  Options are `:page_size`, an absolute monotonic-millisecond `:deadline`,
  and `:clock` (a zero-arity monotonic-millisecond function). The clock option
  permits hosts with an existing monotonic clock abstraction to supply it.
  """
  @spec pull(replica(), replica(), String.t(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def pull(local, remote, log_id, opts \\ []) do
    with {:ok, config} <- config(opts),
         {:ok, result} <- pull_snapshot(local, remote, log_id, config, MapSet.new(), empty()) do
      {:ok, finish(result.acc, 1, result.deadline?, result.forks != [])}
    end
  end

  @doc """
  Synchronize in both directions until equal, fork-isolated, or expired.

  Each pass uses snapshot frontiers. If a non-forked writer advances during a
  pass, the final frontier comparison causes another pass.
  """
  @spec sync(replica(), replica(), String.t(), keyword()) ::
          {:ok, report()} | {:error, term()}
  def sync(left, right, log_id, opts \\ []) do
    with {:ok, config} <- config(opts) do
      sync_passes(left, right, log_id, config, empty(), MapSet.new(), 0)
    end
  end

  defp sync_passes(left, right, log_id, config, acc, forked, passes) do
    if expired?(config) do
      {:ok, finish(acc, passes, true, MapSet.size(forked) > 0)}
    else
      passes = passes + 1

      with {:ok, first} <- pull_snapshot(left, right, log_id, config, forked, acc),
           forked = add_forked(forked, first.forks),
           {:continue, second} <- continue_reverse(first, right, left, log_id, config, forked),
           forked = add_forked(forked, second.forks),
           {:ok, comparison} <- compare_frontiers(left, right, log_id, forked) do
        cond do
          second.deadline? ->
            {:ok, finish(second.acc, passes, true, MapSet.size(forked) > 0)}

          comparison.pending? ->
            sync_passes(left, right, log_id, config, second.acc, forked, passes)

          MapSet.size(forked) > 0 ->
            {:ok, finish(second.acc, passes, false, true)}

          true ->
            {:ok, finish(second.acc, passes, false, false)}
        end
      else
        {:stop, result} ->
          all_forks = add_forked(forked, result.forks)
          {:ok, finish(result.acc, passes, true, MapSet.size(all_forks) > 0)}

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp continue_reverse(%{deadline?: true} = result, _local, _remote, _log_id, _config, _forked),
    do: {:stop, result}

  defp continue_reverse(first, local, remote, log_id, config, forked) do
    case pull_snapshot(local, remote, log_id, config, forked, first.acc) do
      {:ok, second} -> {:continue, second}
      {:error, _reason} = error -> error
    end
  end

  defp pull_snapshot(local, remote, log_id, config, skipped, acc) do
    with {:ok, remote_frontier} <- call(remote, :frontier, [log_id]),
         {:ok, local_frontier} <- call(local, :frontier, [log_id]),
         {:ok, remote_tips} <- tips(remote_frontier),
         {:ok, local_tips} <- tips(local_frontier) do
      remote_tips
      |> Map.values()
      |> Enum.sort_by(& &1.writer_id)
      |> Enum.reduce_while(
        {:ok, %{acc: acc, forks: [], deadline?: false}},
        fn remote_tip, {:ok, state} ->
          writer_id = remote_tip.writer_id
          local_tip = Map.get(local_tips, writer_id, zero_tip(writer_id))

          cond do
            MapSet.member?(skipped, writer_id) ->
              {:cont, {:ok, state}}

            expired?(config) ->
              {:halt, {:ok, %{state | deadline?: true}}}

            equal_seq_fork?(local_tip, remote_tip) ->
              fork = fork(writer_id, local_tip, remote_tip)

              {:cont,
               {:ok,
                %{
                  state
                  | acc: %{state.acc | forks: state.acc.forks ++ [fork]},
                    forks: state.forks ++ [fork]
                }}}

            local_tip.seq < remote_tip.seq ->
              case transfer_writer(
                     local,
                     remote,
                     log_id,
                     local_tip,
                     remote_tip,
                     config,
                     state.acc
                   ) do
                {:ok, next_acc, deadline?} ->
                  {:cont, {:ok, %{state | acc: next_acc, deadline?: deadline?}}}

                {:fork, next_acc} ->
                  fork = fork(writer_id, local_tip, remote_tip)
                  next_acc = %{next_acc | forks: next_acc.forks ++ [fork]}
                  {:cont, {:ok, %{state | acc: next_acc, forks: state.forks ++ [fork]}}}

                {:error, _reason} = error ->
                  {:halt, error}
              end

            true ->
              {:cont, {:ok, state}}
          end
        end
      )
    end
  end

  defp transfer_writer(local, remote, log_id, local_tip, remote_tip, config, acc) do
    transfer_pages(
      local,
      remote,
      log_id,
      remote_tip,
      local_tip.seq,
      local_tip.entry_id,
      config,
      acc
    )
  end

  defp transfer_pages(_local, _remote, _log_id, remote_tip, cursor, _cursor_id, _config, acc)
       when cursor >= remote_tip.seq,
       do: {:ok, acc, false}

  defp transfer_pages(local, remote, log_id, remote_tip, cursor, cursor_id, config, acc) do
    if expired?(config) do
      {:ok, acc, true}
    else
      opts = [after_seq: cursor, through_seq: remote_tip.seq, limit: config.page_size]

      with {:ok, page} <- call(remote, :read_writer, [log_id, remote_tip.writer_id, opts]),
           {:ok, entries} <- page_entries(page),
           {:ok, last_seq, last_id} <-
             validate_page(entries, remote_tip.writer_id, cursor, cursor_id, remote_tip.seq) do
        bytes = Enum.map(entries, & &1.canonical_bytes)

        case call(local, :merge, [log_id, bytes]) do
          {:ok, merged} ->
            next_acc = add_page(acc, merged)

            if expired?(config) do
              {:ok, next_acc, true}
            else
              transfer_pages(
                local,
                remote,
                log_id,
                remote_tip,
                last_seq,
                last_id,
                config,
                next_acc
              )
            end

          {:error, {:writer_fork, _detail}} ->
            {:fork, acc}

          {:error, _reason} = error ->
            error
        end
      else
        {:fork, _detail} -> {:fork, acc}
        {:error, _reason} = error -> error
      end
    end
  end

  defp validate_page([], writer_id, cursor, _cursor_id, through_seq) do
    {:error,
     {:incomplete_writer_range,
      %{writer_id: writer_id, after_seq: cursor, through_seq: through_seq}}}
  end

  defp validate_page(entries, writer_id, cursor, cursor_id, through_seq) do
    Enum.reduce_while(entries, {:ok, cursor, cursor_id}, fn row, {:ok, prior_seq, prior_id} ->
      with {:ok, entry} <- decode_row(row),
           :ok <- check_writer_and_bounds(entry, writer_id, prior_seq, through_seq) do
        if entry.prev_entry_id == prior_id do
          {:cont, {:ok, entry.writer_seq, entry.entry_id}}
        else
          {:halt,
           {:fork,
            %{
              writer_id: writer_id,
              seq: entry.writer_seq,
              expected_prev_entry_id: prior_id,
              actual_prev_entry_id: entry.prev_entry_id
            }}}
        end
      else
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp decode_row(%{canonical_bytes: bytes, writer_seq: row_seq}) when is_binary(bytes) do
    case Jason.decode(bytes) do
      {:ok, decoded} when is_map(decoded) ->
        entry = %{
          writer_id: decoded["writer_id"],
          writer_seq: decoded["writer_seq"],
          entry_id: decoded["entry_id"],
          prev_entry_id: decoded["prev_entry_id"]
        }

        if row_seq == entry.writer_seq,
          do: {:ok, entry},
          else: {:error, {:invalid_writer_range, :row_sequence_mismatch}}

      _ ->
        {:error, {:invalid_writer_range, :invalid_canonical_entry}}
    end
  end

  defp decode_row(_row), do: {:error, {:invalid_writer_range, :invalid_entry_shape}}

  defp check_writer_and_bounds(entry, writer_id, prior_seq, through_seq) do
    cond do
      entry.writer_id != writer_id ->
        {:error, {:invalid_writer_range, :writer_mismatch}}

      entry.writer_seq != prior_seq + 1 ->
        {:error, {:invalid_writer_range, :noncontiguous_sequence}}

      entry.writer_seq > through_seq ->
        {:error, {:invalid_writer_range, :past_advertised_tip}}

      not is_binary(entry.entry_id) ->
        {:error, {:invalid_writer_range, :missing_entry_id}}

      true ->
        :ok
    end
  end

  defp compare_frontiers(left, right, log_id, forked) do
    with {:ok, left_frontier} <- call(left, :frontier, [log_id]),
         {:ok, right_frontier} <- call(right, :frontier, [log_id]),
         {:ok, left_tips} <- tips(left_frontier),
         {:ok, right_tips} <- tips(right_frontier) do
      writer_ids = Map.keys(left_tips) ++ Map.keys(right_tips)

      pending? =
        writer_ids
        |> Enum.uniq()
        |> Enum.reject(&MapSet.member?(forked, &1))
        |> Enum.any?(fn writer_id ->
          Map.get(left_tips, writer_id, zero_tip(writer_id)) !=
            Map.get(right_tips, writer_id, zero_tip(writer_id))
        end)

      {:ok, %{pending?: pending?}}
    end
  end

  defp tips(%{writers: writers}) when is_list(writers) do
    Enum.reduce_while(writers, {:ok, %{}}, fn tip, {:ok, acc} ->
      case normalize_tip(tip) do
        {:ok, normalized} -> {:cont, {:ok, Map.put(acc, normalized.writer_id, normalized)}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp tips(_frontier), do: {:error, {:invalid_frontier, :invalid_shape}}

  defp normalize_tip(%{writer_id: writer_id, seq: seq, entry_id: entry_id})
       when is_binary(writer_id) and is_integer(seq) and seq > 0 and is_binary(entry_id) do
    {:ok, %{writer_id: writer_id, seq: seq, entry_id: entry_id}}
  end

  defp normalize_tip(_tip), do: {:error, {:invalid_frontier, :invalid_tip}}

  defp page_entries(%{entries: entries}) when is_list(entries), do: {:ok, entries}
  defp page_entries(_page), do: {:error, {:invalid_writer_range, :invalid_page_shape}}

  defp call(%{module: module, store: store}, function, args) when is_atom(module) do
    apply(module, function, [store | args])
  end

  defp call(_replica, _function, _args), do: {:error, {:invalid_replica, :invalid_shape}}

  defp config(opts) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    deadline = Keyword.get(opts, :deadline, :infinity)
    clock = Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end)

    cond do
      not (is_integer(page_size) and page_size > 0) ->
        {:error, {:invalid_option, :page_size}}

      deadline != :infinity and not is_integer(deadline) ->
        {:error, {:invalid_option, :deadline}}

      not is_function(clock, 0) ->
        {:error, {:invalid_option, :clock}}

      true ->
        {:ok, %{page_size: page_size, deadline: deadline, clock: clock}}
    end
  end

  defp expired?(%{deadline: :infinity}), do: false
  defp expired?(%{deadline: deadline, clock: clock}), do: clock.() >= deadline

  defp equal_seq_fork?(%{seq: seq, entry_id: local_id}, %{seq: seq, entry_id: remote_id}),
    do: seq > 0 and local_id != remote_id

  defp equal_seq_fork?(_local_tip, _remote_tip), do: false

  defp fork(writer_id, local_tip, remote_tip) do
    %{writer_id: writer_id, local_tip: local_tip, remote_tip: remote_tip}
  end

  defp zero_tip(writer_id), do: %{writer_id: writer_id, seq: 0, entry_id: nil}

  defp add_page(acc, merged) do
    %{
      acc
      | inserted: acc.inserted + Map.get(merged, :inserted, 0),
        present: acc.present + Map.get(merged, :present, 0),
        pages: acc.pages + 1
    }
  end

  defp add_forked(forked, forks) do
    Enum.reduce(forks, forked, &MapSet.put(&2, &1.writer_id))
  end

  defp empty, do: %{inserted: 0, present: 0, pages: 0, forks: []}

  defp finish(acc, passes, deadline?, forks?) do
    forks = acc.forks |> Enum.uniq_by(& &1.writer_id) |> Enum.sort_by(& &1.writer_id)
    forks? = forks? or forks != []

    outcome =
      case {deadline?, forks?} do
        {false, false} -> :converged
        {true, false} -> :deadline
        {false, true} -> :forks
        {true, true} -> :deadline_with_forks
      end

    %{
      outcome: outcome,
      converged?: outcome == :converged,
      progress?: acc.inserted > 0,
      deadline_reached?: deadline?,
      inserted: acc.inserted,
      present: acc.present,
      pages: acc.pages,
      passes: passes,
      forks: forks
    }
  end
end
