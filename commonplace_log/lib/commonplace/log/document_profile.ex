defmodule Commonplace.Log.DocumentProfile do
  @moduledoc """
  Restricted append façade for ordinary, single-lane Documents.

  In the wider authority topology, a Realm hosts a Cell, the Cell authorizes a
  Document, and the Document holds the log handle that reaches persistence.
  This façade is at the Document boundary; neither its log handle nor the
  process and storage behind that handle inherit Cell or Document authority.

  `create_log/2` explicitly creates a log and durably establishes its writer
  identity before returning. `open_log/2` only opens existing logs. Both return
  an opaque handle that binds the log identity, durable writer identity,
  adapter, live store owner, and durable fencing epoch. Taking a later lease
  fences an earlier handle at commit time. Application callers neither supply
  nor receive a writer identity or epoch.

  Activation refuses histories that cannot continue on the one durable lane.
  The base `Commonplace.LogStore.SQLite` and `Commonplace.Log.Engine` APIs remain
  multi-writer capable; this restriction exists only at the Document boundary.

  Rekeying is intentionally absent. Recovery that cannot prove exclusive
  continuation must derive a new lineage log instead of adding a lane here.

  Exact retry is available through `prepare_append/3` and
  `commit_prepared/2`. Preparation requires both `:operation_id` and
  `:created_at`; the timestamp is caller-supplied because generating it during
  preparation would make crash-time re-preparation produce different bytes.
  Prepared appends emit version-2 entries and persist the caller's exact
  operation ID. `append/3`, the non-prepared convenience, and
  `Commonplace.Log.Engine.append` continue to emit version-1 entries because
  neither has an operation ID.
  `prepare_append/3` also takes `lane_index: false` (default `true`): see
  "APPEND-RESCAN-1" below for when a caller should pass it.
  `append_batch/3` is the prepare-then-commit convenience form. The prepared
  value is opaque and binds exact canonical entries without exposing lane
  selection on this public surface.

  Entry-ID derivation is unchanged in principle: IDs are deterministic digests
  of canonical material covering the operation ID, batch index, log ID, bound
  writer ID, writer sequence, predecessor entry ID, canonical body bytes, and
  created-at value. The emitted entry's canonical bytes now also carry the
  operation ID. Preparation searches the existing lane for an exact derived
  batch before selecting the next coordinate. Consequently, identical inputs
  after an ambiguous committed result recover the same bytes.

  Two policy choices, both ruled by jes on 2026-08-23:

    * A prepared operation carries its preparation lease epoch, verified in
      the same transaction as the revision. If a later activation has fenced
      that epoch, commit reports `writer_lease_fenced` and writes nothing.
      A displaced appender is an obsolete authority, not a competing account
      of history, so ordinary handoff is not mislabeled as a data-integrity
      fork — and reporting corruption for a routine failover would train
      operators to ignore the alarm.
    * There is no durable operation registry. Reuse of an operation ID with
      different inputs is caught when prepared attempts compete at an occupied
      coordinate, where merge reports `writer_fork`.

      ACCEPTED LIMITATION, not an oversight: if no earlier attempt landed,
      reuse cannot be detected at all, because nothing exists to conflict
      with and the closed eight-field entry cannot carry an operation ID —
      `extra_top_level_field` is a validation error, so it could only live in
      `body`, which this layer must not interpret. Detection therefore covers
      exactly the cases that could corrupt history and no others. This cost
      was named before the choice was made and was accepted deliberately in
      preference to a durable registry with a retention policy.

      On 2026-08-25 jes knowingly reversed this limitation ("yep, v2 persist"):
      `operation_id` is now persisted in version-2 entries, so a reader can
      derive the applied-operation set by replay. The log STILL keeps no
      registry and STILL does not enforce uniqueness of the key — coordinate
      occupancy and derived entry IDs remain the mechanism.

  The epoch fence is verified at commit rather than checked beforehand. An
  earlier implementation compared the epoch and then called merge; the race
  between those two reads was observed writing a displaced appender's row
  under the newly current epoch. A check that the commit does not consult is
  not a fence.
  """

  alias Commonplace.Log.{Entry, Jcs}
  alias Commonplace.Log.DocumentProfile.Lane
  alias Commonplace.Log.DocumentProfile.Lane.SQLite, as: SQLiteLane
  alias Commonplace.LogStore.SQLite

  defmodule Handle do
    @moduledoc false

    @enforce_keys [:log_id, :writer_id, :adapter, :store, :lane]
    defstruct [:log_id, :writer_id, :adapter, :store, :lane, :retry_context, :lease]

    @type t :: %__MODULE__{
            log_id: String.t(),
            writer_id: String.t(),
            adapter: module(),
            store: term(),
            lane: module(),
            retry_context: term(),
            lease: non_neg_integer()
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

  defmodule Prepared do
    @moduledoc false

    @enforce_keys [:log_id, :lease, :entry_count, :nonce, :ciphertext, :tag]
    defstruct [:log_id, :lease, :entry_count, :nonce, :ciphertext, :tag]

    @type t :: %__MODULE__{
            log_id: String.t(),
            lease: non_neg_integer(),
            entry_count: pos_integer(),
            nonce: binary(),
            ciphertext: binary(),
            tag: binary()
          }
  end

  defimpl Inspect, for: Prepared do
    import Inspect.Algebra

    def inspect(prepared, _opts) do
      concat([
        "#Commonplace.Log.DocumentProfile.Prepared<entries: ",
        Integer.to_string(prepared.entry_count),
        ">"
      ])
    end
  end

  defmodule LaneIndex do
    @moduledoc false

    # APPEND-RESCAN-1: what exact retry needs to know about writer seqs
    # 1..`count`, kept between prepares (see `lane_view/5`). Built only from a
    # lane every entry of which decoded to a map with a valid entry ID, at
    # positions equal to its writer seqs, each chained to the one before.
    # `ops` maps `:erlang.phash2(operation_id)` to the seqs (descending) of the
    # entries carrying that binary operation ID: a superset filter, rechecked
    # on the fetched entry. `ops: :unindexable` is the negative entry: this
    # handle's lane has a row that can never index (rows are immutable), so
    # every prepare takes the original path with ONE lane read.
    @enforce_keys [:key, :count, :last_entry_id, :ops]
    defstruct [:key, :count, :last_entry_id, :ops]
  end

  @lane_index_key {__MODULE__, :lane_index}

  @opaque handle :: Handle.t()
  @opaque prepared :: Prepared.t()
  @type error :: {:error, {atom(), map()}}

  @doc "Explicitly create a Document log and return its single-lane handle."
  @spec create_log(String.t(), keyword()) :: {:ok, handle()} | error()
  def create_log(log_id, opts) when is_binary(log_id) and is_list(opts) do
    with {:ok, lane, lane_store} <- lane(opts),
         :ok <- lane.create_log(log_id, lane_store) do
      activate(lane, lane_store, log_id)
    end
    |> normalize_profile_error()
  end

  @doc "Open an existing single-lane Document log without creating storage."
  @spec open_log(String.t(), keyword()) :: {:ok, handle()} | error()
  def open_log(log_id, opts) when is_binary(log_id) and is_list(opts) do
    with {:ok, lane, lane_store} <- lane(opts),
         :ok <- lane.open_log(log_id, lane_store) do
      activate(lane, lane_store, log_id)
    end
    |> normalize_profile_error()
  end

  @doc "Restore a canonical single-writer prefix into an isolated SQLite target."
  @spec restore_log(String.t(), [binary()], term()) :: {:ok, handle()} | error()
  def restore_log(log_id, entries, capability)
      when is_binary(log_id) and is_list(entries) do
    with {:ok, lane, lane_store} <- lane([]),
         {:ok, _result} <- lane.restore_log(log_id, entries, capability),
         {:ok, handle} <- activate(lane, lane_store, log_id) do
      {:ok, handle}
    end
    |> normalize_profile_error()
  end

  @doc "Append a body on the durable lane bound into `handle`."
  @spec append(handle(), map(), keyword()) :: {:ok, map()} | error()
  def append(%Handle{} = handle, body, opts) when is_map(body) and is_list(opts) do
    with :ok <- validate_append_options(opts),
         {:ok, frontier} <- handle.lane.frontier(handle),
         {:ok, writer_id} <- handle.lane.writer_id(handle),
         :ok <- validate_lane(frontier, handle.writer_id),
         :ok <- validate_bound_writer(writer_id, handle.writer_id),
         {:ok, result} <-
           handle.lane.append_with_epoch(
             handle,
             body,
             created_at(opts),
             handle.lease
           ) do
      {:ok, Map.delete(result, :writer_id)}
    end
    |> normalize_profile_error()
  end

  @doc "Prepare one or more exact canonical entries for idempotent commit."
  @spec prepare_append(handle(), [map()], keyword()) :: {:ok, prepared()} | error()
  def prepare_append(%Handle{} = handle, bodies, opts)
      when is_list(bodies) and is_list(opts) do
    with {:ok, operation_id, created_at} <- validate_prepare_inputs(bodies, opts),
         {:ok, normalized_bodies} <- normalize_bodies(bodies),
         {:ok, frontier} <- handle.lane.frontier(handle),
         {:ok, writer_id} <- handle.lane.writer_id(handle),
         :ok <- validate_lane(frontier, handle.writer_id),
         :ok <- validate_bound_writer(writer_id, handle.writer_id),
         {:ok, canonical_entries} <-
           prepare_entries(
             handle,
             frontier,
             operation_id,
             normalized_bodies,
             created_at,
             Keyword.get(opts, :lane_index, true)
           ),
         {:ok, prepared} <- seal_prepared(handle, canonical_entries) do
      {:ok, prepared}
    end
    |> normalize_profile_error()
  end

  @doc "Commit a prepared operation by replaying its exact canonical entries through merge."
  @spec commit_prepared(handle(), prepared()) :: {:ok, map()} | error()
  def commit_prepared(%Handle{} = handle, %Prepared{} = prepared) do
    with :ok <- validate_prepared_binding(handle, prepared),
         {:ok, canonical_entries} <- open_prepared(handle, prepared),
         {:ok, result} <-
           handle.lane.merge_with_epoch(handle, canonical_entries, prepared.lease) do
      {:ok, Map.delete(result, :writer_id)}
    end
    |> normalize_profile_error()
    |> strip_writer_identity()
  end

  @doc "Prepare and commit an ordered batch with the exact-retry semantics of the prepared form."
  @spec append_batch(handle(), [map()], keyword()) :: {:ok, map()} | error()
  def append_batch(%Handle{} = handle, bodies, opts)
      when is_list(bodies) and is_list(opts) do
    with {:ok, prepared} <- prepare_append(handle, bodies, opts) do
      commit_prepared(handle, prepared)
    end
  end

  defp activate(lane, lane_store, log_id) do
    with {:ok, activation} <- lane.activate(log_id, lane_store) do
      {:ok,
       %Handle{
         log_id: log_id,
         writer_id: activation.writer_id,
         adapter: activation.adapter,
         store: activation.store,
         lane: lane,
         retry_context: :crypto.strong_rand_bytes(32),
         lease: activation.lease
       }}
    end
  end

  defp lane(opts) do
    case Keyword.get(opts, :lane) do
      nil ->
        case Keyword.get(opts, :adapter, SQLite) do
          SQLite ->
            {:ok, SQLiteLane, nil}

          unsupported ->
            {:error, {:storage, %{reason: {:unsupported_profile_adapter, unsupported}}}}
        end

      {lane, store} when is_atom(lane) ->
        {:ok, lane, store}

      unsupported ->
        {:error, {:storage, %{reason: {:unsupported_profile_lane, unsupported}}}}
    end
  end

  defp validate_lane(frontier, writer_id), do: Lane.validate_lane(frontier, writer_id)

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

  defp validate_prepare_inputs(bodies, opts) do
    unsupported = Keyword.keys(opts) -- [:operation_id, :created_at, :lane_index]

    cond do
      unsupported != [] ->
        invalid_prepared({:unsupported_options, unsupported})

      bodies == [] ->
        invalid_prepared(:bodies_required)

      not Enum.all?(bodies, &is_map/1) ->
        invalid_prepared(:bodies_must_be_maps)

      not Keyword.has_key?(opts, :operation_id) ->
        invalid_prepared(:operation_id_required)

      not (is_binary(opts[:operation_id]) and opts[:operation_id] != "") ->
        invalid_prepared(:operation_id_must_be_nonempty_string)

      not String.valid?(opts[:operation_id]) ->
        invalid_prepared(:operation_id_must_be_valid_utf8_string)

      byte_size(opts[:operation_id]) > 256 ->
        invalid_prepared(:operation_id_must_be_at_most_256_bytes)

      not Keyword.has_key?(opts, :created_at) ->
        invalid_prepared(:created_at_required)

      not (is_binary(opts[:created_at]) or match?(%DateTime{}, opts[:created_at])) ->
        invalid_prepared(:created_at_must_be_datetime_or_string)

      not is_boolean(Keyword.get(opts, :lane_index, true)) ->
        invalid_prepared(:lane_index_must_be_boolean)

      true ->
        {:ok, opts[:operation_id], encode_created_at(opts[:created_at])}
    end
  end

  defp invalid_prepared(reason), do: {:error, {:invalid_prepared_append, %{reason: reason}}}

  defp normalize_bodies(bodies) do
    Enum.reduce_while(bodies, {:ok, []}, fn body, {:ok, normalized} ->
      with {:ok, json} <- Jason.encode(body),
           {:ok, decoded} <- Jason.decode(json) do
        {:cont, {:ok, [decoded | normalized]}}
      else
        {:error, reason} ->
          {:halt, {:error, {:invalid_prepared_append, %{reason: reason}}}}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      error -> error
    end
  end

  defp prepare_entries(handle, frontier, operation_id, bodies, created_at, lane_index?) do
    tip = List.first(frontier.writers)

    view =
      if lane_index?,
        do: lane_view(handle, tip, operation_id, bodies, created_at),
        else: read_lane(handle, tip)

    with {:ok, existing} <- view,
         {:ok, canonical_entries} <-
           find_or_build_entries(handle, existing, tip, operation_id, bodies, created_at) do
      {:ok, canonical_entries}
    end
  end

  defp read_lane(_handle, nil), do: {:ok, []}

  defp read_lane(handle, %{seq: tip_seq}) do
    with {:ok, %{entries: entries, next_after_seq: nil}} <-
           handle.lane.read_writer(handle,
             after_seq: 0,
             through_seq: tip_seq,
             limit: tip_seq
           ) do
      {:ok, Enum.map(entries, & &1.canonical_bytes)}
    end
  end

  # ── APPEND-RESCAN-1: exact retry without reading the whole lane ──────────
  #
  # `find_existing_batch/5` over the full lane decodes every entry on every
  # prepare: O(n) per append, O(n²) over a catch-up. The lane is append-only
  # (entries are immutable in storage), so what the scan needs -- the count,
  # that every entry is a map with a valid entry ID, and where each operation
  # ID occurs -- is kept per process in a `LaneIndex` and extended by the new
  # seqs only. It is keyed by the whole handle identity (a fresh activation
  # gets a fresh `retry_context`) and must chain onto the frontier's tip, or it
  # is rebuilt. When the certified path of `find_existing_batch/5` applies
  # (`last_start > 1` and `candidate_scan_certified?/6`), the result is
  # `scan_matching_operations/7`, which only acts at seqs carrying the
  # operation ID; those windows are fetched and the scan runs on them. Anything
  # else -- no index, a failed read, an uncertified candidate -- reads the
  # lane and takes the original path unchanged.
  #
  # RETENTION AND THRASH. One index per PROCESS (`@lane_index_key`), for the
  # last handle it prepared on: about a map entry per lane seq, held until the
  # process exits or prepares on another handle. A process alternating between
  # handles rebuilds on each switch -- one full lane read, the cost every
  # prepare had before. It pays off for a long-lived process appending to one
  # log (the DocHost). A caller whose operation IDs never retry and whose
  # prepares run in short-lived processes (RealmNode: a fresh UUIDv7 per
  # request, one Bandit connection process per request) passes
  # `lane_index: false` and keeps the original single-read path.
  defp lane_view(handle, tip, operation_id, bodies, created_at) do
    batch_size = length(bodies)

    with %{seq: tip_seq} <- tip,
         last_start = tip_seq - batch_size + 1,
         true <- last_start > 1,
         {:ok, index} <- lane_index(handle, tip),
         {:ok, [{_bytes, predecessor}]} <- read_parsed(handle, last_start - 2, last_start - 1),
         true <-
           certified_build?(
             handle,
             index.count,
             fn -> true end,
             fn -> predecessor["entry_id"] end,
             last_start,
             operation_id,
             bodies,
             created_at
           ),
         {:ok, windows} <- operation_windows(handle, index, last_start, operation_id, batch_size) do
      {:ok, {:indexed, windows}}
    else
      _ -> read_lane(handle, tip)
    end
  end

  # `{seq, predecessor entry ID, exact bytes of seqs seq..seq+batch_size-1}`
  # for each seq <= last_start whose entry passes `scan_matching_operations/7`'s
  # test, ascending.
  defp operation_windows(handle, index, last_start, operation_id, batch_size) do
    index.ops
    |> Map.get(:erlang.phash2(operation_id), [])
    |> Enum.reverse()
    |> Enum.filter(&(&1 <= last_start))
    |> Enum.reduce_while({:ok, []}, fn seq, {:ok, windows} ->
      from = max(seq - 2, 0)

      case read_parsed(handle, from, seq + batch_size - 1) do
        {:ok, rows} ->
          {before, [{_bytes, entry} | _] = batch} = Enum.split(rows, seq - 1 - from)
          predecessor = if before == [], do: nil, else: elem(hd(before), 1)["entry_id"]

          if entry["version"] == 2 and entry["operation_id"] == operation_id,
            do: {:cont, {:ok, [{seq, predecessor, Enum.map(batch, &elem(&1, 0))} | windows]}},
            else: {:cont, {:ok, windows}}

        _error ->
          {:halt, :error}
      end
    end)
    |> case do
      {:ok, windows} -> {:ok, Enum.reverse(windows)}
      error -> error
    end
  end

  # The index for `handle` through the frontier's tip: the cached one extended
  # by the new seqs, else one rebuilt from seq 1. A lane that cannot be indexed
  # is remembered (`ops: :unindexable`) so it is not read twice per prepare.
  defp lane_index(handle, %{seq: tip_seq, entry_id: tip_entry_id})
       when is_integer(tip_seq) and is_binary(tip_entry_id) do
    key = {handle.log_id, handle.writer_id, handle.retry_context, handle.store}
    empty = %LaneIndex{key: key, count: 0, last_entry_id: nil, ops: %{}}

    case Process.get(@lane_index_key) do
      %LaneIndex{key: ^key, ops: :unindexable} ->
        :error

      %LaneIndex{key: ^key, count: count} = cached when count <= tip_seq ->
        with :error <- index_through(handle, cached, tip_seq, tip_entry_id),
             do: if(count > 0, do: index_through(handle, empty, tip_seq, tip_entry_id), else: :error)

      _ ->
        index_through(handle, empty, tip_seq, tip_entry_id)
    end
  end

  defp lane_index(_handle, _tip), do: :error

  defp index_through(handle, from, tip_seq, tip_entry_id) do
    case read_parsed(handle, from.count, tip_seq) do
      {:ok, rows} ->
        case extend_index(from, rows) do
          {:ok, %LaneIndex{last_entry_id: ^tip_entry_id} = index} ->
            Process.put(@lane_index_key, index)
            {:ok, index}

          # The rows chain, but not onto this frontier's tip: nothing says
          # the next prepare's tip will not agree, so forget, do not mark.
          {:ok, _index} ->
            Process.delete(@lane_index_key)
            :error

          :error ->
            if from.count == 0, do: Process.put(@lane_index_key, %{from | ops: :unindexable})
            :error
        end

      {:error, :unindexable} ->
        if from.count == 0, do: Process.put(@lane_index_key, %{from | ops: :unindexable})
        :error

      :error ->
        Process.delete(@lane_index_key)
        :error
    end
  end

  defp extend_index(index, rows) do
    Enum.reduce_while(rows, {:ok, index}, fn {_bytes, entry}, {:ok, index} ->
      operation_id = entry["operation_id"]

      if Entry.uuid_problem(entry["entry_id"]) == nil and
           entry["prev_entry_id"] == index.last_entry_id do
        ops =
          if is_binary(operation_id),
            do: Map.update(index.ops, :erlang.phash2(operation_id), [index.count + 1], &[index.count + 1 | &1]),
            else: index.ops

        {:cont,
         {:ok, %{index | count: index.count + 1, last_entry_id: entry["entry_id"], ops: ops}}}
      else
        {:halt, :error}
      end
    end)
  end

  # Writer seqs `after_seq+1..through_seq` as `{canonical bytes, decoded map}`.
  # `{:error, :unindexable}` when a row is out of place or does not decode to a
  # map (rows are immutable: it never will); `:error` when the read itself fails.
  defp read_parsed(_handle, seq, seq), do: {:ok, []}

  defp read_parsed(handle, after_seq, through_seq) when through_seq > after_seq do
    case handle.lane.read_writer(handle,
           after_seq: after_seq,
           through_seq: through_seq,
           limit: through_seq - after_seq
         ) do
      {:ok, %{entries: entries, next_after_seq: nil}}
      when length(entries) == through_seq - after_seq ->
        entries
        |> Enum.with_index(after_seq + 1)
        |> Enum.reduce_while({:ok, []}, fn {row, seq}, {:ok, acc} ->
          with %{writer_seq: ^seq, canonical_bytes: bytes} <- row,
               {:ok, entry} when is_map(entry) <- Jason.decode(bytes) do
            {:cont, {:ok, [{bytes, entry} | acc]}}
          else
            _ -> {:halt, {:error, :unindexable}}
          end
        end)
        |> case do
          {:ok, rows} -> {:ok, Enum.reverse(rows)}
          error -> error
        end

      _ ->
        :error
    end
  end

  defp read_parsed(_handle, _after_seq, _through_seq), do: :error

  defp find_or_build_entries(handle, existing, tip, operation_id, bodies, created_at) do
    case find_existing_batch(handle, existing, operation_id, bodies, created_at) do
      {:ok, entries} ->
        {:ok, entries}

      :not_found ->
        start_seq = if tip, do: tip.seq + 1, else: 1
        prev_entry_id = if tip, do: tip.entry_id, else: nil

        build_entries(
          handle.log_id,
          handle.writer_id,
          start_seq,
          prev_entry_id,
          operation_id,
          bodies,
          created_at
        )
    end
  end

  defp find_existing_batch(handle, {:indexed, windows}, operation_id, bodies, created_at) do
    # `scan_matching_operations/7` over only the seqs whose entry carries
    # `operation_id`; every other seq there is `{:cont, :not_found}`.
    Enum.reduce_while(windows, :not_found, fn {seq, predecessor, batch}, :not_found ->
      with {:ok, candidate} <-
             build_entries(
               handle.log_id,
               handle.writer_id,
               seq,
               predecessor,
               operation_id,
               bodies,
               created_at
             ),
           true <- batch == candidate do
        {:halt, {:ok, candidate}}
      else
        false -> {:cont, :not_found}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp find_existing_batch(handle, existing, operation_id, bodies, created_at) do
    batch_size = length(bodies)
    last_start = length(existing) - batch_size + 1

    if last_start < 1 do
      :not_found
    else
      parsed = Enum.map(existing, &Jason.decode!/1)

      parsed_index = List.to_tuple(parsed)

      if last_start > 1 and
           candidate_scan_certified?(
             handle,
             parsed_index,
             last_start,
             operation_id,
             bodies,
             created_at
           ) do
        scan_matching_operations(
          handle,
          List.to_tuple(existing),
          parsed_index,
          last_start,
          operation_id,
          bodies,
          created_at
        )
      else
        scan_existing_batch(
          handle,
          existing,
          parsed,
          last_start,
          operation_id,
          bodies,
          created_at
        )
      end
    end
  end

  # Keep the original scan as the authority for uncertain/invalid input. In
  # particular, it can return an early replay before a later candidate is too
  # large, or return an early validation error before a matching operation ID.
  defp scan_existing_batch(handle, existing, parsed, last_start, operation_id, bodies, created_at) do
    batch_size = length(bodies)

    Enum.reduce_while(1..last_start, :not_found, fn start_seq, :not_found ->
      prev_entry_id =
        if start_seq == 1,
          do: nil,
          else: parsed |> Enum.at(start_seq - 2) |> Map.fetch!("entry_id")

      with {:ok, candidate} <-
             build_entries(
               handle.log_id,
               handle.writer_id,
               start_seq,
               prev_entry_id,
               operation_id,
               bodies,
               created_at
             ),
           true <- Enum.slice(existing, start_seq - 1, batch_size) == candidate do
        {:halt, {:ok, candidate}}
      else
        false -> {:cont, :not_found}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  # The largest positional start generates the largest sequence at every batch
  # index. A successful build there certifies deterministic validation for all
  # earlier candidates: bodies/time/operation/log/writer stay identical; derived
  # IDs and all nonnull predecessors are lowercase ASCII UUIDs of length 36;
  # sequence 1's nil predecessor is shorter; positive safe integer decimal widths
  # do not shrink as the sequence grows. This proof depends on Entry's current
  # closed fields, canonicalization and size check. It does not promise immunity
  # to resource exhaustion or other operational faults after work is skipped.
  defp candidate_scan_certified?(handle, parsed, last_start, operation_id, bodies, created_at) do
    certified_build?(
      handle,
      tuple_size(parsed),
      fn ->
        parsed
        |> Tuple.to_list()
        |> Enum.all?(fn entry ->
          is_map(entry) and Entry.uuid_problem(Map.get(entry, "entry_id")) == nil
        end)
      end,
      fn -> elem(parsed, last_start - 2)["entry_id"] end,
      last_start,
      operation_id,
      bodies,
      created_at
    )
  end

  # The certificate itself, shared with APPEND-RESCAN-1's `lane_view/5` (whose
  # index exists only for an all-valid lane). `valid?` and `predecessor` are
  # evaluated inside the `try`, as the original scan did.
  defp certified_build?(handle, count, valid?, predecessor, last_start, operation_id, bodies, created_at) do
    try do
      if count <= 9_007_199_254_740_991 and valid?.() do
        case build_entries(
               handle.log_id,
               handle.writer_id,
               last_start,
               predecessor.(),
               operation_id,
               bodies,
               created_at
             ) do
          {:ok, _entries} -> true
          _ -> false
        end
      else
        false
      end
    catch
      _kind, _reason -> false
    end
  end

  defp scan_matching_operations(
         handle,
         existing,
         parsed,
         last_start,
         operation_id,
         bodies,
         created_at
       ) do
    batch_size = length(bodies)

    Enum.reduce_while(0..(last_start - 1), :not_found, fn index, :not_found ->
      entry = elem(parsed, index)

      # Necessary, never sufficient: exact replay still compares every byte of
      # the derived batch with the original contiguous history at this position.
      if entry["version"] == 2 and entry["operation_id"] == operation_id do
        predecessor = if index == 0, do: nil, else: elem(parsed, index - 1)["entry_id"]

        with {:ok, candidate} <-
               build_entries(
                 handle.log_id,
                 handle.writer_id,
                 index + 1,
                 predecessor,
                 operation_id,
                 bodies,
                 created_at
               ),
             true <- Enum.map(index..(index + batch_size - 1), &elem(existing, &1)) == candidate do
          {:halt, {:ok, candidate}}
        else
          false -> {:cont, :not_found}
          {:error, _reason} = error -> {:halt, error}
        end
      else
        {:cont, :not_found}
      end
    end)
  end

  defp build_entries(
         log_id,
         writer_id,
         start_seq,
         prev_entry_id,
         operation_id,
         bodies,
         created_at
       ) do
    bodies
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, [], prev_entry_id}, fn {body, index}, {:ok, entries, prev_id} ->
      writer_seq = start_seq + index
      body_bytes = Jcs.canonicalize(body)

      entry_id =
        derived_entry_id(%{
          "operation_id" => operation_id,
          "batch_index" => index,
          "log_id" => log_id,
          "writer_id" => writer_id,
          "writer_seq" => writer_seq,
          "prev_entry_id" => prev_id,
          "body_bytes" => body_bytes,
          "created_at" => created_at
        })

      raw =
        Jason.encode!(%{
          "version" => 2,
          "log_id" => log_id,
          "entry_id" => entry_id,
          "operation_id" => operation_id,
          "writer_id" => writer_id,
          "writer_seq" => writer_seq,
          "prev_entry_id" => prev_id,
          "created_at" => created_at,
          "body" => body
        })

      case Entry.validate_entry(raw) do
        {:ok, canonical_bytes} ->
          {:cont, {:ok, [canonical_bytes | entries], entry_id}}

        {:error, code, reason} ->
          protocol_code = if code == "entry_too_large", do: :entry_too_large, else: :invalid_entry
          {:halt, {:error, {protocol_code, %{reason: reason}}}}
      end
    end)
    |> case do
      {:ok, entries, _last_id} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp derived_entry_id(material) do
    <<uuid_bytes::binary-size(16), _rest::binary>> =
      :crypto.hash(:sha256, Jcs.canonicalize(material))

    hex = Base.encode16(uuid_bytes, case: :lower)

    <<a::binary-size(8), b::binary-size(4), c::binary-size(4), d::binary-size(4),
      e::binary-size(12)>> = hex

    Enum.join([a, b, c, d, e], "-")
  end

  defp seal_prepared(handle, canonical_entries) do
    entry_count = length(canonical_entries)
    nonce = :crypto.strong_rand_bytes(12)
    aad = prepared_aad(handle.log_id, handle.lease, entry_count)
    plaintext = :erlang.term_to_binary(canonical_entries)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        handle.retry_context,
        nonce,
        plaintext,
        aad,
        16,
        true
      )

    {:ok,
     %Prepared{
       log_id: handle.log_id,
       lease: handle.lease,
       entry_count: entry_count,
       nonce: nonce,
       ciphertext: ciphertext,
       tag: tag
     }}
  end

  defp open_prepared(handle, prepared) do
    aad = prepared_aad(prepared.log_id, prepared.lease, prepared.entry_count)

    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           handle.retry_context,
           prepared.nonce,
           prepared.ciphertext,
           aad,
           prepared.tag,
           false
         ) do
      plaintext when is_binary(plaintext) ->
        case :erlang.binary_to_term(plaintext, [:safe]) do
          entries when is_list(entries) and length(entries) == prepared.entry_count ->
            {:ok, entries}

          _other ->
            invalid_prepared(:invalid_prepared_payload)
        end

      :error ->
        invalid_prepared(:invalid_prepared_payload)
    end
  rescue
    ArgumentError -> invalid_prepared(:invalid_prepared_payload)
  end

  defp prepared_aad(log_id, lease, entry_count),
    do: :erlang.term_to_binary({log_id, lease, entry_count})

  defp validate_prepared_binding(
         %Handle{log_id: log_id, lease: lease},
         %Prepared{log_id: log_id, lease: lease}
       ),
       do: :ok

  defp validate_prepared_binding(%Handle{log_id: log_id}, %Prepared{log_id: log_id}),
    do: {:error, {:writer_lease_fenced, %{}}}

  defp validate_prepared_binding(_handle, _prepared),
    do: {:error, {:invalid_prepared_append, %{reason: :handle_mismatch}}}

  defp created_at(opts), do: Keyword.get_lazy(opts, :created_at, &DateTime.utc_now/0)

  defp encode_created_at(%DateTime{} = created_at), do: DateTime.to_iso8601(created_at)
  defp encode_created_at(created_at) when is_binary(created_at), do: created_at

  defp normalize_profile_error({:error, :obsolete_epoch}),
    do: {:error, {:writer_lease_fenced, %{}}}

  defp normalize_profile_error({:error, :not_found}),
    do: {:error, {:log_not_found, %{}}}

  defp normalize_profile_error({:error, code, reason}) when is_binary(code) do
    protocol_code = if code == "entry_too_large", do: :entry_too_large, else: :invalid_entry
    {:error, {protocol_code, %{reason: reason}}}
  end

  defp normalize_profile_error({:error, {:storage, %{reason: :obsolete_epoch}}}),
    do: {:error, {:writer_lease_fenced, %{}}}

  defp normalize_profile_error({:error, {:storage, %{reason: reason}}} = error) do
    if contains_reason?(reason, :lock_unavailable) do
      {:error, {:writer_lease_unavailable, %{}}}
    else
      error
    end
  end

  defp normalize_profile_error(result), do: result

  defp strip_writer_identity({:error, {code, details}}) when is_map(details),
    do: {:error, {code, Map.delete(details, :writer_id)}}

  defp strip_writer_identity(result), do: result

  defp contains_reason?(reason, wanted) when reason == wanted, do: true

  defp contains_reason?(term, wanted) when is_tuple(term) do
    term |> Tuple.to_list() |> Enum.any?(&contains_reason?(&1, wanted))
  end

  defp contains_reason?(term, wanted) when is_list(term),
    do: Enum.any?(term, &contains_reason?(&1, wanted))

  defp contains_reason?(term, wanted) when is_map(term),
    do:
      Enum.any?(term, fn {key, value} ->
        contains_reason?(key, wanted) or contains_reason?(value, wanted)
      end)

  defp contains_reason?(_term, _wanted), do: false
end
