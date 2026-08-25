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
  `append_batch/3` is the prepare-then-commit convenience form. The prepared
  value is opaque and binds exact canonical entries without exposing lane
  selection on this public surface.

  Entry IDs are deterministic digests of the operation ID, batch index, log
  ID, bound writer ID, writer sequence, predecessor entry ID, canonical body
  bytes, and created-at value. Preparation searches the existing lane for an
  exact derived batch before selecting the next coordinate. Consequently,
  identical inputs after an ambiguous committed result recover the same bytes.

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
             created_at
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
    unsupported = Keyword.keys(opts) -- [:operation_id, :created_at]

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

      not Keyword.has_key?(opts, :created_at) ->
        invalid_prepared(:created_at_required)

      not (is_binary(opts[:created_at]) or match?(%DateTime{}, opts[:created_at])) ->
        invalid_prepared(:created_at_must_be_datetime_or_string)

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

  defp prepare_entries(handle, frontier, operation_id, bodies, created_at) do
    tip = List.first(frontier.writers)

    with {:ok, existing} <- read_lane(handle, tip),
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

  defp find_existing_batch(handle, existing, operation_id, bodies, created_at) do
    batch_size = length(bodies)
    last_start = length(existing) - batch_size + 1

    if last_start < 1 do
      :not_found
    else
      parsed = Enum.map(existing, &Jason.decode!/1)

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
          "version" => 1,
          "log_id" => log_id,
          "entry_id" => entry_id,
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
