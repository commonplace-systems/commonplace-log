defmodule Commonplace.Log.Persistence.CloudflareSidecar do
  @moduledoc """
  Persistence adapter for the configured HTTP sidecar.

  The handle contains only a base URL, an injectable transport, and the
  extra request headers to send on every call. Routing and endpoint
  resolution remain outside this adapter: a realm is selected by giving the
  gateway's realm prefix in `base_url` (`"https://host/realms/acme-1"`), and
  gateway authentication by a `{"authorization", "Bearer ..."}` header.

  Request headers are never placed in an error term, so a bearer token
  cannot leak into a logged error.
  """

  @behaviour Commonplace.Log.Persistence

  alias Commonplace.Log.Persistence.{CommitPlan, ReadSet}
  alias __MODULE__.Httpc

  @enforce_keys [:base_url, :transport, :transport_options, :headers]
  defstruct [:base_url, :transport, :transport_options, :headers]

  @type header :: {String.t(), String.t()}

  @type t :: %__MODULE__{
          base_url: String.t(),
          transport: module(),
          transport_options: term(),
          headers: [header()]
        }

  @headers [{"content-type", "application/json"}]
  @commit_reconciliation_attempts 3
  @error_body_limit 4_096

  @doc """
  Builds a handle.

  Options:

    * `:transport` — module implementing the transport behaviour (default `Httpc`)
    * `:transport_options` — opaque term passed to the transport on every call
    * `:headers` — list of `{name, value}` string tuples appended to the request
      headers on every call (default `[]`); raises `ArgumentError` otherwise
  """
  @spec new(String.t(), keyword()) :: t()
  def new(base_url, options \\ []) when is_binary(base_url) and is_list(options) do
    %__MODULE__{
      base_url: String.trim_trailing(base_url, "/"),
      transport: Keyword.get(options, :transport, Httpc),
      transport_options: Keyword.get(options, :transport_options, []),
      headers: validate_headers(Keyword.get(options, :headers, []))
    }
  end

  defp validate_headers(headers) when is_list(headers) do
    if Enum.all?(headers, &match?({name, value} when is_binary(name) and is_binary(value), &1)) do
      headers
    else
      raise ArgumentError,
            ":headers must be a list of {name, value} binary tuples, got: " <>
              inspect(headers, limit: 8, printable_limit: 64)
    end
  end

  defp validate_headers(headers) do
    raise ArgumentError,
          ":headers must be a list of {name, value} binary tuples, got: " <>
            inspect(headers, limit: 8, printable_limit: 64)
  end

  @impl true
  def create_log(%__MODULE__{} = store, log_id, metadata) do
    payload =
      %{"log_id" => log_id}
      |> put_metadata(metadata, "format_version")
      |> put_metadata(metadata, "created_at")

    post(store, "/create-log", payload, 201, &parse_plain_ok/1)
  end

  @impl true
  def take_lease(%__MODULE__{} = store, log_id) do
    post(store, "/take-lease", %{"log_id" => log_id}, 200, fn value ->
      with :ok <- exact_keys(value, ["ok", "lease_epoch"]),
           true <- value["ok"] === true,
           {:ok, epoch} <- positive_integer(value["lease_epoch"]) do
        {:ok, epoch}
      else
        false -> protocol("take-lease success has non-true ok")
        {:error, _reason} = error -> error
      end
    end)
  end

  @impl true
  def read_set(%__MODULE__{} = store, log_id, query) do
    payload = %{
      "log_id" => log_id,
      "writers" => Map.fetch!(query, :writers),
      "coordinates" =>
        Enum.map(Map.fetch!(query, :coordinates), fn {writer_id, writer_seq} ->
          %{"writer_id" => writer_id, "writer_seq" => writer_seq}
        end),
      "entry_ids" => Map.fetch!(query, :entry_ids)
    }

    post(store, "/read-set", payload, 200, &parse_read_set(&1, log_id))
  end

  @impl true
  def commit(%__MODULE__{} = store, %CommitPlan{} = plan) do
    payload = %{
      "log_id" => plan.log_id,
      "expected_revision" => plan.expected_revision,
      "expected_epoch" => plan.expected_epoch,
      "insert_entries" => Enum.map(plan.insert_entries, &encode_entry/1),
      "put_tips" => Enum.map(plan.put_tips, &encode_tip/1)
    }

    result =
      post(store, "/commit", payload, 200, fn value ->
        with :ok <- exact_keys(value, ["ok", "revision"]),
             true <- value["ok"] === true,
             {:ok, revision} <- non_negative_integer(value["revision"]) do
          {:ok, revision}
        else
          false -> protocol("commit success has non-true ok")
          {:error, _reason} = error -> error
        end
      end)

    case result do
      {:error, {:transport_error, _reason} = commit_error} ->
        reconcile_commit(store, plan, commit_error)

      result ->
        result
    end
  end

  @impl true
  def frontier(%__MODULE__{} = store, log_id) do
    post(store, "/frontier", %{"log_id" => log_id}, 200, &parse_frontier/1)
  end

  @impl true
  def read_writer(%__MODULE__{} = store, log_id, writer_id, options) do
    payload =
      %{
        "log_id" => log_id,
        "writer_id" => writer_id,
        "after_seq" => Keyword.fetch!(options, :after_seq),
        "limit" => Keyword.fetch!(options, :limit)
      }
      |> maybe_put("through_seq", Keyword.get(options, :through_seq))

    post(store, "/read-writer", payload, 200, &parse_writer_page/1)
  end

  @impl true
  def tail_local(%__MODULE__{} = store, log_id, options) do
    payload = %{
      "log_id" => log_id,
      "after_arrival" => Keyword.fetch!(options, :after_arrival),
      "limit" => Keyword.fetch!(options, :limit)
    }

    post(store, "/tail-local", payload, 200, &parse_local_page/1)
  end

  defp post(store, path, payload, success_status, parse_success) do
    body = Jason.encode!(payload)

    case store.transport.request(
           :post,
           store.base_url <> path,
           @headers ++ store.headers,
           body,
           store.transport_options
         ) do
      {:error, reason} ->
        {:error, {:transport_error, reason}}

      {:ok, %{status: status, headers: headers, body: response_body}}
      when is_integer(status) and is_list(headers) and is_binary(response_body) and status >= 500 and
             status != 507 ->
        {:error, {:transport_error, {:http_status, status, error_details(response_body)}}}

      {:ok, %{status: status, headers: headers, body: response_body}}
      when is_integer(status) and is_list(headers) and is_binary(response_body) and
             status in [401, 403] ->
        {:error, {:unauthorized, %{status: status, body: error_details(response_body).body}}}

      {:ok, %{status: status, headers: headers, body: response_body}}
      when is_integer(status) and is_list(headers) and is_binary(response_body) ->
        with {:ok, value} <- decode_json_object(response_body) do
          if status == success_status do
            parse_success.(value)
          else
            parse_error_response(status, value)
          end
        end

      {:ok, response} ->
        protocol({:malformed_transport_response, response})

      response ->
        protocol({:invalid_transport_return, response})
    end
  end

  # Response details for a rejected request. Only the response is described;
  # the request (and so any bearer token in its headers) never enters an error.
  defp error_details(response_body) do
    %{body: binary_part(response_body, 0, min(byte_size(response_body), @error_body_limit))}
  end

  defp reconcile_commit(_store, %CommitPlan{insert_entries: []}, commit_error) do
    commit_outcome_unknown(commit_error, :no_insert_entries)
  end

  defp reconcile_commit(store, %CommitPlan{} = plan, commit_error) do
    query = %{
      writers: [],
      coordinates: [],
      entry_ids: Enum.map(plan.insert_entries, & &1.entry_id)
    }

    reconcile_commit(store, plan, query, commit_error, @commit_reconciliation_attempts)
  end

  defp reconcile_commit(store, plan, query, commit_error, attempts_left) do
    case read_set(store, plan.log_id, query) do
      {:ok, read_set} ->
        classify_reconciliation(plan, read_set, commit_error)

      {:error, {:transport_error, _reason}}
      when attempts_left > 1 ->
        reconcile_commit(store, plan, query, commit_error, attempts_left - 1)

      {:error, reconciliation_error} ->
        commit_outcome_unknown(commit_error, reconciliation_error)
    end
  end

  defp classify_reconciliation(plan, read_set, commit_error) do
    submitted = Map.new(plan.insert_entries, &{&1.entry_id, &1.canonical_bytes})
    observed = Map.take(read_set.entry_ids, Map.keys(submitted))

    cond do
      map_size(observed) == 0 ->
        {:error, commit_error}

      Enum.all?(submitted, fn {entry_id, bytes} -> observed[entry_id] == bytes end) ->
        {:ok, read_set.revision}

      true ->
        present_ids = Map.keys(observed) |> Enum.sort()

        mismatched_ids =
          Enum.flat_map(observed, fn {entry_id, bytes} ->
            if submitted[entry_id] == bytes, do: [], else: [entry_id]
          end)
          |> Enum.sort()

        commit_outcome_unknown(commit_error, %{
          reason: :partial_or_mismatched_entries,
          present_entry_ids: present_ids,
          mismatched_entry_ids: mismatched_ids
        })
    end
  end

  defp commit_outcome_unknown(commit_error, reconciliation_error) do
    {:error,
     {:commit_outcome_unknown,
      %{commit_error: commit_error, reconciliation_error: reconciliation_error}}}
  end

  defp parse_plain_ok(value) do
    with :ok <- exact_keys(value, ["ok"]),
         true <- value["ok"] === true do
      :ok
    else
      false -> protocol("success has non-true ok")
      {:error, _reason} = error -> error
    end
  end

  defp parse_read_set(value, expected_log_id) do
    with :ok <- exact_keys(value, ["ok", "read_set"]),
         true <- value["ok"] === true,
         %{} = read_set <- value["read_set"],
         :ok <-
           exact_keys(read_set, [
             "log_id",
             "format_version",
             "revision",
             "lease_epoch",
             "tips",
             "coordinates",
             "entry_ids"
           ]),
         {:ok, log_id} <- string(read_set["log_id"]),
         :ok <- matching_log_id(log_id, expected_log_id),
         {:ok, _format_version} <- non_negative_integer(read_set["format_version"]),
         {:ok, revision} <- non_negative_integer(read_set["revision"]),
         {:ok, lease_epoch} <- non_negative_integer(read_set["lease_epoch"]),
         {:ok, tips} <- parse_tips(read_set["tips"]),
         {:ok, coordinates} <- parse_coordinates(read_set["coordinates"]),
         {:ok, entry_ids} <- parse_entry_ids(read_set["entry_ids"]) do
      {:ok,
       %ReadSet{
         log_id: log_id,
         revision: revision,
         lease_epoch: lease_epoch,
         tips: tips,
         coordinates: coordinates,
         entry_ids: entry_ids
       }}
    else
      false -> protocol("read-set success has non-true ok")
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("read_set is not an object")
    end
  end

  defp parse_tips(value) do
    with {:ok, rows} <- parse_list(value, &parse_read_tip/1),
         {:ok, tips} <- unique_map(rows, fn {writer_id, tip} -> {writer_id, tip} end) do
      {:ok, tips}
    end
  end

  defp parse_read_tip(row) do
    with %{} <- row,
         :ok <- exact_keys(row, ["writer_id", "last_seq", "last_entry_id"]),
         {:ok, writer_id} <- string(row["writer_id"]),
         {:ok, seq} <- positive_integer(row["last_seq"]),
         {:ok, entry_id} <- string(row["last_entry_id"]) do
      {:ok, {writer_id, %{seq: seq, entry_id: entry_id}}}
    else
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("tip is not an object")
    end
  end

  defp parse_coordinates(value) do
    with {:ok, rows} <- parse_list(value, &parse_coordinate/1),
         {:ok, coordinates} <- unique_map(rows, fn {coordinate, bytes} -> {coordinate, bytes} end) do
      {:ok, coordinates}
    end
  end

  defp parse_coordinate(row) do
    with %{} <- row,
         :ok <- exact_keys(row, ["writer_id", "writer_seq", "canonical_bytes"]),
         {:ok, writer_id} <- string(row["writer_id"]),
         {:ok, writer_seq} <- positive_integer(row["writer_seq"]),
         {:ok, bytes} <- decode_base64(row["canonical_bytes"]) do
      {:ok, {{writer_id, writer_seq}, bytes}}
    else
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("coordinate is not an object")
    end
  end

  defp parse_entry_ids(value) do
    with {:ok, rows} <- parse_list(value, &parse_entry_id/1),
         {:ok, entry_ids} <- unique_map(rows, fn {entry_id, bytes} -> {entry_id, bytes} end) do
      {:ok, entry_ids}
    end
  end

  defp parse_entry_id(row) do
    with %{} <- row,
         :ok <- exact_keys(row, ["entry_id", "canonical_bytes"]),
         {:ok, entry_id} <- string(row["entry_id"]),
         {:ok, bytes} <- decode_base64(row["canonical_bytes"]) do
      {:ok, {entry_id, bytes}}
    else
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("entry-id row is not an object")
    end
  end

  defp parse_frontier(value) do
    with :ok <- exact_keys(value, ["ok", "frontier"]),
         true <- value["ok"] === true,
         %{} = frontier <- value["frontier"],
         :ok <- exact_keys(frontier, ["writers"]),
         {:ok, writers} <- parse_list(frontier["writers"], &parse_frontier_writer/1),
         true <- writers == Enum.sort_by(writers, & &1.writer_id),
         true <- length(writers) == length(Enum.uniq_by(writers, & &1.writer_id)) do
      {:ok, %{writers: writers}}
    else
      false -> protocol("frontier writers are not uniquely sorted")
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("frontier is not an object")
    end
  end

  defp parse_frontier_writer(row) do
    with %{} <- row,
         :ok <- exact_keys(row, ["writer_id", "seq", "entry_id"]),
         {:ok, writer_id} <- string(row["writer_id"]),
         {:ok, seq} <- positive_integer(row["seq"]),
         {:ok, entry_id} <- string(row["entry_id"]) do
      {:ok, %{writer_id: writer_id, seq: seq, entry_id: entry_id}}
    else
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("frontier writer is not an object")
    end
  end

  defp parse_writer_page(value) do
    with :ok <- exact_keys(value, ["ok", "page"]),
         true <- value["ok"] === true,
         %{} = page <- value["page"],
         :ok <- exact_keys(page, ["entries", "next_after_seq"]),
         {:ok, entries} <- parse_list(page["entries"], &parse_writer_entry/1),
         {:ok, cursor} <- nullable_positive_integer(page["next_after_seq"]) do
      {:ok, %{entries: entries, next_after_seq: cursor}}
    else
      false -> protocol("writer page success has non-true ok")
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("writer page is not an object")
    end
  end

  defp parse_writer_entry(row) do
    with %{} <- row,
         :ok <- exact_keys(row, ["canonical_bytes", "writer_seq"]),
         {:ok, bytes} <- decode_base64(row["canonical_bytes"]),
         {:ok, writer_seq} <- positive_integer(row["writer_seq"]) do
      {:ok, %{canonical_bytes: bytes, writer_seq: writer_seq}}
    else
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("writer entry is not an object")
    end
  end

  defp parse_local_page(value) do
    with :ok <- exact_keys(value, ["ok", "page"]),
         true <- value["ok"] === true,
         %{} = page <- value["page"],
         :ok <- exact_keys(page, ["entries", "next_after_arrival"]),
         {:ok, entries} <- parse_list(page["entries"], &parse_local_entry/1),
         {:ok, cursor} <- nullable_positive_integer(page["next_after_arrival"]) do
      {:ok, %{entries: entries, next_after_arrival: cursor}}
    else
      false -> protocol("local page success has non-true ok")
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("local page is not an object")
    end
  end

  defp parse_local_entry(row) do
    with %{} <- row,
         :ok <- exact_keys(row, ["canonical_bytes", "arrival_seq"]),
         {:ok, bytes} <- decode_base64(row["canonical_bytes"]),
         {:ok, arrival_seq} <- positive_integer(row["arrival_seq"]) do
      {:ok, %{canonical_bytes: bytes, arrival_seq: arrival_seq}}
    else
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("local entry is not an object")
    end
  end

  defp parse_error_response(status, value) do
    with :ok <- exact_keys(value, ["ok", "error"]),
         true <- value["ok"] === false,
         %{} = error <- value["error"],
         :ok <- exact_keys(error, ["code"]),
         {:ok, code} <- string(error["code"]),
         {:ok, term} <- storage_error(status, code) do
      {:error, term}
    else
      false -> protocol({:unexpected_http_status, status})
      {:error, _reason} = error -> error
      value when not is_map(value) -> protocol("error is not an object")
    end
  end

  defp storage_error(404, "not_found"), do: {:ok, :not_found}
  defp storage_error(400, "malformed_request"), do: {:ok, :malformed_request}
  defp storage_error(409, "stale_revision"), do: {:ok, :stale_revision}
  defp storage_error(409, "obsolete_epoch"), do: {:ok, :obsolete_epoch}
  defp storage_error(409, "constraint_violation"), do: {:ok, :constraint_violation}
  defp storage_error(409, "log_mismatch"), do: {:ok, :log_mismatch}
  defp storage_error(507, "storage_full"), do: {:ok, :storage_full}
  defp storage_error(status, code), do: protocol({:unexpected_error, status, code})

  defp matching_log_id(log_id, log_id), do: :ok
  defp matching_log_id(_log_id, _expected_log_id), do: {:error, :log_mismatch}

  defp encode_entry(row) do
    %{
      "log_id" => row.log_id,
      "entry_id" => row.entry_id,
      "writer_id" => row.writer_id,
      "writer_seq" => row.writer_seq,
      "prev_entry_id" => row.prev_entry_id,
      "created_at" => row.created_at,
      "canonical_bytes" => Base.encode64(row.canonical_bytes)
    }
  end

  defp encode_tip(tip) do
    %{
      "writer_id" => tip.writer_id,
      "last_seq" => tip.seq,
      "last_entry_id" => tip.entry_id
    }
  end

  defp put_metadata(payload, metadata, key) do
    atom_key = String.to_existing_atom(key)

    case Map.fetch(metadata, atom_key) do
      {:ok, value} ->
        Map.put(payload, key, value)

      :error ->
        if Map.has_key?(metadata, key), do: Map.put(payload, key, metadata[key]), else: payload
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp decode_json_object(body) do
    case Jason.decode(body) do
      {:ok, %{} = value} -> {:ok, value}
      {:ok, _value} -> protocol("response JSON is not an object")
      {:error, error} -> protocol({:invalid_json, Exception.message(error)})
    end
  end

  defp exact_keys(value, expected) when is_map(value) do
    if Map.keys(value) |> Enum.sort() == Enum.sort(expected) do
      :ok
    else
      protocol({:unexpected_keys, Map.keys(value), expected})
    end
  end

  defp exact_keys(value, _expected), do: protocol({:not_an_object, value})

  defp parse_list(value, parser) when is_list(value) do
    Enum.reduce_while(value, {:ok, []}, fn item, {:ok, items} ->
      case parser.(item) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | items]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, items} -> {:ok, Enum.reverse(items)}
      {:error, _reason} = error -> error
    end
  end

  defp parse_list(_value, _parser), do: protocol("expected a list")

  defp unique_map(rows, mapper) do
    map = Map.new(rows, mapper)
    if map_size(map) == length(rows), do: {:ok, map}, else: protocol("duplicate response row")
  end

  defp string(value) when is_binary(value), do: {:ok, value}
  defp string(_value), do: protocol("expected a string")

  defp non_negative_integer(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_negative_integer(_value), do: protocol("expected a non-negative integer")

  defp positive_integer(value) when is_integer(value) and value > 0, do: {:ok, value}
  defp positive_integer(_value), do: protocol("expected a positive integer")

  defp nullable_positive_integer(nil), do: {:ok, nil}
  defp nullable_positive_integer(value), do: positive_integer(value)

  defp decode_base64(value) when is_binary(value) and rem(byte_size(value), 4) == 0 do
    case Base.decode64(value, padding: true) do
      {:ok, bytes} -> {:ok, bytes}
      :error -> protocol("invalid standard padded base64")
    end
  end

  defp decode_base64(_value), do: protocol("invalid standard padded base64")

  defp protocol(reason), do: {:error, {:protocol_error, reason}}
end
