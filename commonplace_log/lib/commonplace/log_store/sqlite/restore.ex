defmodule Commonplace.LogStore.SQLite.RestoreCapability do
  @moduledoc false

  @enforce_keys [:target, :frontier, :nonce]
  defstruct [:target, :frontier, :nonce]
end

defmodule Commonplace.LogStore.SQLite.Restore do
  @moduledoc false

  alias Commonplace.Log.{Entry, Frontier}
  alias Commonplace.LogStore.SQLite.RestoreCapability

  @max_entries 4_096
  @max_bytes 32 * 1024 * 1024

  @spec capability(String.t(), Frontier.t()) :: RestoreCapability.t()
  def capability(log_id, %Frontier{} = frontier) when is_binary(log_id) do
    %RestoreCapability{target: log_id, frontier: frontier, nonce: :crypto.strong_rand_bytes(32)}
  end

  @spec prepare(String.t(), [binary()], RestoreCapability.t()) ::
          {:ok, map()} | {:error, term()}
  def prepare(log_id, entries, %RestoreCapability{} = capability)
      when is_binary(log_id) and is_list(entries) do
    with :ok <- validate_capability(log_id, capability),
         {:ok, expected} <- expected_frontier(capability.frontier),
         {:ok, canonical} <- canonical_entries(entries),
         {:ok, chain} <- validate_chain(log_id, canonical, expected) do
      {:ok,
       %{
         log_id: log_id,
         entries: canonical,
         writer_id: chain.writer_id,
         writer_seq: chain.seq,
         tip_entry_id: chain.entry_id,
         frontier_digest: expected.digest,
         entry_count: length(canonical)
       }}
    end
  end

  def prepare(_log_id, _entries, _capability), do: {:error, :restore_capability_required}

  defp validate_capability(log_id, %RestoreCapability{target: log_id, nonce: nonce})
       when is_binary(nonce) and byte_size(nonce) >= 16,
       do: :ok

  defp validate_capability(_log_id, _capability), do: {:error, :restore_capability_mismatch}

  defp expected_frontier(%Frontier{tips: [tip]}) when is_binary(tip) do
    with :ok <- valid_uuid(tip) do
      {:ok, %{tip_entry_id: tip, digest: digest(%Frontier{tips: [tip]})}}
    end
  end

  defp expected_frontier(%Frontier{}), do: {:error, :restore_single_writer_required}
  defp expected_frontier(_frontier), do: {:error, :restore_frontier_shape}

  defp canonical_entries(entries) when length(entries) == 0,
    do: {:error, :restore_entries_required}

  defp canonical_entries(entries) when length(entries) > @max_entries,
    do: {:error, :restore_entry_limit}

  defp canonical_entries(entries) do
    Enum.reduce_while(entries, {:ok, [], 0}, fn raw, {:ok, acc, bytes} ->
      if is_binary(raw) and bytes + byte_size(raw) <= @max_bytes do
        case Entry.validate_entry(raw) do
          {:ok, ^raw} -> {:cont, {:ok, [raw | acc], bytes + byte_size(raw)}}
          {:ok, _canonical} -> {:halt, {:error, :restore_noncanonical_entry}}
          {:error, code, reason} -> {:halt, {:error, {code, reason}}}
        end
      else
        {:halt, {:error, :restore_entry_limit}}
      end
    end)
    |> case do
      {:ok, entries, _bytes} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp validate_chain(log_id, [first | _] = entries, %{tip_entry_id: tip}) do
    first_parsed = Jason.decode!(first)
    expected = %{writer_id: first_parsed["writer_id"], seq: length(entries), entry_id: tip}

    with :ok <- valid_uuid(expected.writer_id),
         :ok <- validate_chain_entries(log_id, entries, expected) do
      {:ok, expected}
    end
  end

  defp validate_chain(_log_id, [], _expected), do: {:error, :restore_entries_required}

  defp validate_chain_entries(log_id, entries, expected) do
    entries
    |> Enum.with_index(1)
    |> Enum.reduce_while({:ok, nil}, fn {raw, seq}, {:ok, previous_id} ->
      parsed = Jason.decode!(raw)

      cond do
        parsed["log_id"] != log_id ->
          {:halt, {:error, :restore_log_mismatch}}

        parsed["writer_id"] != expected.writer_id ->
          {:halt, {:error, :restore_writer_mismatch}}

        parsed["writer_seq"] != seq ->
          {:halt, {:error, :restore_writer_gap}}

        parsed["prev_entry_id"] != previous_id ->
          {:halt, {:error, :restore_predecessor_mismatch}}

        true ->
          {:cont, {:ok, parsed["entry_id"]}}
      end
    end)
    |> case do
      {:ok, tip} when tip == expected.entry_id -> :ok
      {:ok, _tip} -> {:error, :restore_frontier_mismatch}
      {:error, _reason} = error -> error
    end
  end

  defp digest(%Frontier{} = frontier), do: :crypto.hash(:sha256, Frontier.encode(frontier))

  defp valid_uuid(value) when is_binary(value) do
    case Entry.uuid_problem(value) do
      nil -> :ok
      _reason -> {:error, :restore_frontier_shape}
    end
  end

  defp valid_uuid(_value), do: {:error, :restore_frontier_shape}
end
