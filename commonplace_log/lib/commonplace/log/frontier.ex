defmodule Commonplace.Log.Frontier do
  @moduledoc """
  A portable, verifiable log prefix named only by its maximal entry IDs.

  The version-1 wire value is canonical JCS with exactly two fields:

      {"tips":["entry-id"],"type":"commonplace.log.frontier/v1"}

  Tips are sorted by their UTF-8 entry-ID bytes. Coordinates never enter the
  value or its encoding, so ordinary struct equality has exactly the same
  semantics as encoded-value equality.

  Store operations accept a bound log map of the form
  `%{module: persistence_module, store: store, log_id: log_id}`.
  `read_through/3` returns canonical entry bytes in `writer_id` byte order,
  then ascending `writer_seq` within each lane. It never uses replica-local
  arrival order.
  """

  alias Commonplace.Log.{Entry, Jcs}

  @type type_error_reason ::
          :invalid_json
          | :frontier_not_object
          | :missing_type
          | :missing_tips
          | :extra_top_level_field
          | :wrong_type
          | :tips_not_list
          | :tip_not_string
          | :tip_uuid_not_lowercase
          | :tip_uuid_malformed
          | :duplicate_tip
          | :tips_not_canonical_order
          | :non_canonical_encoding
          | :unknown_tip
          | :multiple_tips_for_lane

  defmodule Error do
    @moduledoc "A typed frontier codec or verification failure."

    @enforce_keys [:operation, :reason]
    defstruct [:operation, :reason, :entry_id, :writer_id]

    @type t :: %__MODULE__{
            operation: :decode | :verify,
            reason: Commonplace.Log.Frontier.type_error_reason(),
            entry_id: String.t() | nil,
            writer_id: String.t() | nil
          }
  end

  @type t :: %__MODULE__{tips: [String.t()]}
  @type log :: %{module: module(), store: term(), log_id: String.t()}

  @enforce_keys [:tips]
  defstruct tips: []

  @wire_type "commonplace.log.frontier/v1"
  @default_page_size 500

  @doc "Construct an encode-ready frontier, sorting entry IDs by their bytes."
  @spec new([String.t()]) :: t()
  def new(tips) when is_list(tips) do
    case validate_tips(tips, false) do
      :ok -> %__MODULE__{tips: Enum.sort(tips)}
      {:error, %Error{} = error} -> raise ArgumentError, "invalid frontier tips: #{error.reason}"
    end
  end

  @doc "Encode a frontier as canonical RFC 8785 JSON bytes."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{tips: tips}) do
    case validate_tips(tips, true) do
      :ok -> Jcs.canonicalize(%{"type" => @wire_type, "tips" => tips})
      {:error, %Error{} = error} -> raise ArgumentError, "invalid frontier: #{error.reason}"
    end
  end

  @doc "Decode and structurally validate canonical version-1 frontier bytes."
  @spec decode(binary()) :: {:ok, t()} | {:error, Error.t()}
  def decode(raw) when is_binary(raw) do
    with {:ok, parsed} <- decode_json(raw),
         :ok <- validate_shape(parsed),
         tips = parsed["tips"],
         :ok <- validate_tips(tips, true),
         :ok <- validate_canonical_bytes(raw, parsed) do
      {:ok, %__MODULE__{tips: tips}}
    end
  end

  def decode(_raw), do: decode_error(:invalid_json)

  @doc "Construct the current frontier value for a bound log."
  @spec frontier_value(log()) :: {:ok, t()} | {:error, term()}
  def frontier_value(%{module: module, store: store, log_id: log_id}) do
    with {:ok, %{writers: writers}} <- module.frontier(store, log_id) do
      tips =
        writers
        |> Enum.sort_by(& &1.entry_id)
        |> Enum.map(& &1.entry_id)

      {:ok, %__MODULE__{tips: tips}}
    end
  end

  @doc """
  Read exactly the prefix named by `frontier`.

  Results are canonical entry bytes ordered by `writer_id`, then by ascending
  `writer_seq`. `:page_size` controls adapter paging and defaults to 500.
  """
  @spec read_through(log(), t(), keyword()) :: {:ok, [binary()]} | {:error, term()}
  def read_through(
        %{module: module, store: store, log_id: log_id},
        %__MODULE__{tips: tips},
        opts
      )
      when is_list(opts) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)

    with :ok <- validate_frontier_value(tips),
         :ok <- validate_page_size(page_size),
         {:ok, read_set} <-
           module.read_set(store, log_id, %{writers: [], coordinates: [], entry_ids: tips}),
         {:ok, coordinates} <- resolve_tips(tips, read_set.entry_ids),
         :ok <- validate_one_tip_per_lane(coordinates) do
      coordinates
      |> Enum.sort_by(fn coordinate -> {coordinate.writer_id, coordinate.writer_seq} end)
      |> Enum.reduce_while({:ok, []}, fn coordinate, {:ok, lanes} ->
        case read_lane(module, store, log_id, coordinate, page_size, 0, []) do
          {:ok, entries} -> {:cont, {:ok, [entries | lanes]}}
          {:error, _reason} = error -> {:halt, error}
        end
      end)
      |> case do
        {:ok, lanes} -> {:ok, lanes |> Enum.reverse() |> List.flatten()}
        error -> error
      end
    end
  end

  defp decode_json(raw) do
    if String.valid?(raw) do
      case Jason.decode(raw) do
        {:ok, parsed} -> {:ok, parsed}
        {:error, _error} -> decode_error(:invalid_json)
      end
    else
      decode_error(:invalid_json)
    end
  end

  defp validate_shape(parsed) when not is_map(parsed), do: decode_error(:frontier_not_object)

  defp validate_shape(parsed) do
    keys = Map.keys(parsed)

    cond do
      not Map.has_key?(parsed, "type") -> decode_error(:missing_type)
      not Map.has_key?(parsed, "tips") -> decode_error(:missing_tips)
      Enum.sort(keys) != ["tips", "type"] -> decode_error(:extra_top_level_field)
      parsed["type"] != @wire_type -> decode_error(:wrong_type)
      not is_list(parsed["tips"]) -> decode_error(:tips_not_list)
      true -> :ok
    end
  end

  defp validate_tips(tips, require_order) do
    with :ok <- validate_tip_uuids(tips),
         :ok <- validate_unique_tips(tips),
         :ok <- validate_tip_order(tips, require_order) do
      :ok
    end
  end

  defp validate_tip_uuids(tips) do
    Enum.reduce_while(tips, :ok, fn tip, :ok ->
      case Entry.uuid_problem(tip) do
        nil -> {:cont, :ok}
        :uuid_not_string -> {:halt, decode_error(:tip_not_string)}
        :uuid_not_lowercase -> {:halt, decode_error(:tip_uuid_not_lowercase)}
        :uuid_malformed -> {:halt, decode_error(:tip_uuid_malformed)}
      end
    end)
  end

  defp validate_unique_tips(tips) do
    if length(Enum.uniq(tips)) == length(tips),
      do: :ok,
      else: decode_error(:duplicate_tip)
  end

  defp validate_tip_order(_tips, false), do: :ok

  defp validate_tip_order(tips, true) do
    if tips == Enum.sort(tips), do: :ok, else: decode_error(:tips_not_canonical_order)
  end

  defp validate_canonical_bytes(raw, parsed) do
    if raw == Jcs.canonicalize(parsed), do: :ok, else: decode_error(:non_canonical_encoding)
  end

  defp validate_frontier_value(tips) do
    case validate_tips(tips, true) do
      :ok -> :ok
      {:error, %Error{reason: reason}} -> verify_error(reason, [])
    end
  end

  defp resolve_tips(tips, entries_by_id) do
    Enum.reduce_while(tips, {:ok, []}, fn entry_id, {:ok, coordinates} ->
      case Map.fetch(entries_by_id, entry_id) do
        :error ->
          {:halt, verify_error(:unknown_tip, entry_id: entry_id)}

        {:ok, canonical_bytes} ->
          parsed = Jason.decode!(canonical_bytes)

          coordinate = %{
            entry_id: entry_id,
            writer_id: parsed["writer_id"],
            writer_seq: parsed["writer_seq"]
          }

          {:cont, {:ok, [coordinate | coordinates]}}
      end
    end)
    |> case do
      {:ok, coordinates} -> {:ok, Enum.reverse(coordinates)}
      error -> error
    end
  end

  defp validate_one_tip_per_lane(coordinates) do
    duplicate_lane =
      coordinates
      |> Enum.group_by(& &1.writer_id)
      |> Enum.filter(fn {_writer_id, tips} -> length(tips) > 1 end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.sort()
      |> List.first()

    case duplicate_lane do
      nil -> :ok
      writer_id -> verify_error(:multiple_tips_for_lane, writer_id: writer_id)
    end
  end

  defp read_lane(module, store, log_id, coordinate, page_size, after_seq, entries) do
    options = [
      after_seq: after_seq,
      through_seq: coordinate.writer_seq,
      limit: page_size
    ]

    case module.read_writer(store, log_id, coordinate.writer_id, options) do
      {:ok, %{entries: page, next_after_seq: nil}} ->
        {:ok, Enum.reverse([Enum.map(page, & &1.canonical_bytes) | entries]) |> List.flatten()}

      {:ok, %{entries: page, next_after_seq: next_after_seq}} ->
        read_lane(
          module,
          store,
          log_id,
          coordinate,
          page_size,
          next_after_seq,
          [Enum.map(page, & &1.canonical_bytes) | entries]
        )

      {:error, _reason} = error ->
        error
    end
  end

  defp validate_page_size(size) when is_integer(size) and size > 0, do: :ok
  defp validate_page_size(size), do: {:error, {:invalid_page_size, size}}

  defp decode_error(reason), do: {:error, %Error{operation: :decode, reason: reason}}

  defp verify_error(reason, fields) do
    {:error, struct!(Error, Keyword.merge([operation: :verify, reason: reason], fields))}
  end
end
