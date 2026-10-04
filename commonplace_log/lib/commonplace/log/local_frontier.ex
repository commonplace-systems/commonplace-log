defmodule Commonplace.Log.LocalFrontier do
  @moduledoc """
  A VERIFIABLE replica-local coordinate F in one log incarnation
  (CHECKPOINT-SNAP-1, Phase B round 3).

  `Commonplace.Log.Frontier` names a portable prefix by its tips and is read
  in writer order. This value names something different: the exact
  replica-local ARRIVAL prefix `arrival_seq <= F` of one local copy of a log,
  so a caller that already holds derived state through F (a disposable local
  checkpoint) can read only the entries after F, without the prefix.

  It is never portable and never crosses a replica boundary: arrival order is
  local bookkeeping (see `Commonplace.Log.Persistence`). It carries:

    * `log_id` -- the log;
    * `incarnation` -- lowercase hex SHA-256 identifying THIS local copy of the
      log: the stored log identity, its creation stamp and format, the restore
      marker if the copy was restored, and the database file instance (device
      and inode). A log deleted and re-created, restored/imported, or copied
      file-by-file to another place has a different incarnation, and every F
      from the old one is refused;
    * `arrival_seq` -- F itself (`0` is the empty prefix);
    * `entry_id`, `entry_digest` -- the entry stored AT arrival F and the
      SHA-256 of its canonical bytes (both nil iff F is 0);
    * `writers` -- for every writer with an entry at or before F, the highest
      writer sequence at or before F, that entry's id and its arrival
      coordinate, sorted by writer id.

  ## What verifying F checks, without reading the prefix

  `Commonplace.Log.Persistence` adapters that serve local suffixes recompute,
  from the log, inside one read transaction:

    * the incarnation (which includes the database FILE instance, so a copied
      data dir is a different incarnation);
    * the entry stored at arrival F, by id and by the SHA-256 of its canonical
      bytes;
    * for every writer, its highest sequence at or before F, that entry's id
      and its arrival (one index probe per writer);

  and refuse F unless all equal the stored value.

  What that establishes, and under which assumptions: entry ids are UUIDs, not
  content hashes, so the per-writer boundary does not by itself commit to the
  entries below it. It is the log's own invariants that do: within one
  incarnation entries are immutable (triggers) and arrival coordinates are
  never reused; `(writer_id, writer_seq)` is unique; and a replica accepts a
  writer's entries only gaplessly and in sequence order (`writer_gap`), each
  naming its predecessor. Under those, matching boundaries mean the prefix at
  or before F is the set `w:1..seq_w` for each writer -- the same set as when F
  was taken -- in the same arrival order.

  ## What it does NOT prove

  It does not survive a violation of those invariants inside the same file
  instance (a database edited by hand, or rolled back in place and re-fed the
  identical entry set with identical per-writer boundary arrivals but a
  different interleaving). That is outside the local-filesystem trust boundary
  checkpoints already assume; the consumer's background full-replay
  verification is the backstop.

  The wire form is canonical JCS (see `encode/1`); `decode/1` refuses any
  non-canonical or ill-shaped bytes.
  """

  alias Commonplace.Log.{Entry, Jcs}

  @wire_type "commonplace.log.local-frontier/v1"
  @keys ~w(arrival_seq entry_digest entry_id incarnation log_id type writers)
  @writer_keys ~w(arrival_seq entry_id seq writer_id)

  @enforce_keys [:log_id, :incarnation, :arrival_seq, :entry_id, :entry_digest, :writers]
  defstruct [:log_id, :incarnation, :arrival_seq, :entry_id, :entry_digest, writers: []]

  @type writer :: %{
          writer_id: String.t(),
          seq: pos_integer(),
          entry_id: String.t(),
          arrival_seq: pos_integer()
        }

  @type t :: %__MODULE__{
          log_id: String.t(),
          incarnation: String.t(),
          arrival_seq: non_neg_integer(),
          entry_id: String.t() | nil,
          entry_digest: String.t() | nil,
          writers: [writer()]
        }

  @doc "Lowercase hex SHA-256 of a canonical entry's bytes."
  @spec entry_digest(binary()) :: String.t()
  def entry_digest(canonical_bytes) when is_binary(canonical_bytes),
    do: :crypto.hash(:sha256, canonical_bytes) |> Base.encode16(case: :lower)

  @doc "Canonical JCS bytes of a well-formed value; raises on an ill-formed one."
  @spec encode(t()) :: binary()
  def encode(%__MODULE__{} = frontier) do
    case validate(frontier) do
      :ok -> Jcs.canonicalize(to_wire(frontier))
      {:error, reason} -> raise ArgumentError, "invalid local frontier: #{inspect(reason)}"
    end
  end

  @doc "Decodes canonical bytes; any other shape is `{:error, {:invalid_local_frontier, reason}}`."
  @spec decode(binary()) :: {:ok, t()} | {:error, {:invalid_local_frontier, atom()}}
  def decode(raw) when is_binary(raw) do
    with {:ok, parsed} <- json(raw),
         {:ok, frontier} <- from_wire(parsed),
         :ok <- validate(frontier),
         :ok <- if(Jcs.canonicalize(parsed) == raw, do: :ok, else: bad(:non_canonical)) do
      {:ok, frontier}
    end
  end

  def decode(_raw), do: bad(:not_binary)

  @doc "Structural validity of a value (types, ordering, the F-0 rule)."
  @spec validate(term()) :: :ok | {:error, {:invalid_local_frontier, atom()}}
  def validate(%__MODULE__{} = f) do
    cond do
      not uuid?(f.log_id) -> bad(:log_id)
      not hex64?(f.incarnation) -> bad(:incarnation)
      not (is_integer(f.arrival_seq) and f.arrival_seq >= 0) -> bad(:arrival_seq)
      f.arrival_seq == 0 and (f.entry_id != nil or f.entry_digest != nil or f.writers != []) -> bad(:origin)
      f.arrival_seq > 0 and not uuid?(f.entry_id) -> bad(:entry_id)
      f.arrival_seq > 0 and not hex64?(f.entry_digest) -> bad(:entry_digest)
      f.arrival_seq > 0 and f.writers == [] -> bad(:writers)
      not writers_valid?(f.writers, f.arrival_seq) -> bad(:writers)
      true -> :ok
    end
  end

  def validate(_other), do: bad(:not_local_frontier)

  defp writers_valid?(writers, arrival) when is_list(writers) do
    Enum.all?(writers, fn
      %{writer_id: w, seq: s, entry_id: e, arrival_seq: a} ->
        uuid?(w) and is_integer(s) and s > 0 and uuid?(e) and is_integer(a) and a > 0 and a <= arrival

      _ ->
        false
    end) and sorted_unique?(Enum.map(writers, & &1.writer_id))
  end

  defp writers_valid?(_writers, _arrival), do: false

  defp sorted_unique?(ids), do: ids == Enum.sort(Enum.uniq(ids))

  defp to_wire(f) do
    %{
      "type" => @wire_type,
      "log_id" => f.log_id,
      "incarnation" => f.incarnation,
      "arrival_seq" => f.arrival_seq,
      "entry_id" => f.entry_id,
      "entry_digest" => f.entry_digest,
      "writers" =>
        Enum.map(f.writers, fn w ->
          %{
            "writer_id" => w.writer_id,
            "seq" => w.seq,
            "entry_id" => w.entry_id,
            "arrival_seq" => w.arrival_seq
          }
        end)
    }
  end

  defp from_wire(%{} = p) do
    cond do
      Enum.sort(Map.keys(p)) != @keys -> bad(:keys)
      p["type"] != @wire_type -> bad(:type)
      not is_list(p["writers"]) -> bad(:writers)
      true -> from_wire_writers(p)
    end
  end

  defp from_wire(_), do: bad(:not_object)

  defp from_wire_writers(p) do
    p["writers"]
    |> Enum.reduce_while({:ok, []}, fn
      %{} = w, {:ok, acc} ->
        if Enum.sort(Map.keys(w)) == @writer_keys do
          {:cont,
           {:ok,
            [
              %{
                writer_id: w["writer_id"],
                seq: w["seq"],
                entry_id: w["entry_id"],
                arrival_seq: w["arrival_seq"]
              }
              | acc
            ]}}
        else
          {:halt, bad(:writer_keys)}
        end

      _other, _acc ->
        {:halt, bad(:writer_not_object)}
    end)
    |> case do
      {:ok, writers} ->
        {:ok,
         %__MODULE__{
           log_id: p["log_id"],
           incarnation: p["incarnation"],
           arrival_seq: p["arrival_seq"],
           entry_id: p["entry_id"],
           entry_digest: p["entry_digest"],
           writers: Enum.reverse(writers)
         }}

      error ->
        error
    end
  end

  defp json(raw) do
    if String.valid?(raw) do
      case Jason.decode(raw) do
        {:ok, parsed} -> {:ok, parsed}
        {:error, _} -> bad(:invalid_json)
      end
    else
      bad(:invalid_json)
    end
  end

  defp uuid?(value), do: is_binary(value) and Entry.uuid_problem(value) == nil
  defp hex64?(value), do: is_binary(value) and value =~ ~r/\A[0-9a-f]{64}\z/

  defp bad(reason), do: {:error, {:invalid_local_frontier, reason}}
end
