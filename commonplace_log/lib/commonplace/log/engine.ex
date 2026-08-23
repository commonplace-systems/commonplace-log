defmodule Commonplace.Log.Engine do
  @moduledoc """
  Normative coordinator for append and merge semantics.

  Persistence modules provide coherent read sets and atomic revision-guarded
  commits. Entry construction, canonical validation, merge classification,
  and stale-revision retries remain in this module.
  """

  alias Commonplace.Log.{Entry, MergePlan, UUID}
  alias Commonplace.Log.Persistence.CommitPlan

  @max_stale_retries 3

  @doc "The number of stale-revision results retried before exhaustion."
  @spec max_stale_retries() :: non_neg_integer()
  def max_stale_retries, do: @max_stale_retries

  @doc "Construct, validate, and atomically append one local-writer entry."
  @spec append(module(), term(), String.t(), String.t(), map(), DateTime.t() | String.t()) ::
          {:ok, map()} | {:error, term()} | {:error, String.t(), String.t()}
  def append(persistence_mod, store, log_id, writer_id, body, created_at) do
    append(persistence_mod, store, log_id, writer_id, body, created_at, :current)
  end

  @doc "Append while requiring the caller-bound lease epoch at commit time."
  @spec append(
          module(),
          term(),
          String.t(),
          String.t(),
          map(),
          DateTime.t() | String.t(),
          non_neg_integer()
        ) :: {:ok, map()} | {:error, term()} | {:error, String.t(), String.t()}
  def append(persistence_mod, store, log_id, writer_id, body, created_at, expected_epoch) do
    retry_append(
      persistence_mod,
      store,
      log_id,
      writer_id,
      body,
      created_at,
      expected_epoch,
      0
    )
  end

  @doc "Validate, classify, and atomically merge canonicalizable entry bytes."
  @spec merge(module(), term(), String.t(), [binary()]) ::
          {:ok, map()} | {:error, term()} | {:error, String.t(), String.t()}
  def merge(persistence_mod, store, log_id, raw_entries) when is_list(raw_entries) do
    with {:ok, batch} <- validate_batch(raw_entries, log_id) do
      retry_merge(persistence_mod, store, log_id, batch, 0)
    end
  end

  defp retry_append(
         persistence_mod,
         store,
         log_id,
         writer_id,
         body,
         created_at,
         expected_epoch,
         stale_retries
       ) do
    query = %{writers: [writer_id], coordinates: [], entry_ids: []}

    with {:ok, read_set} <- persistence_mod.read_set(store, log_id, query),
         {:ok, entry} <- build_append_entry(log_id, writer_id, body, created_at, read_set.tips),
         plan =
           append_commit_plan(
             log_id,
             read_set.revision,
             resolve_epoch(expected_epoch, read_set.lease_epoch),
             entry
           ) do
      case persistence_mod.commit(store, plan) do
        {:ok, revision} ->
          {:ok,
           %{
             entry_id: entry.entry_id,
             writer_id: writer_id,
             writer_seq: entry.writer_seq,
             revision: revision
           }}

        {:error, :stale_revision} when stale_retries < @max_stale_retries ->
          retry_append(
            persistence_mod,
            store,
            log_id,
            writer_id,
            body,
            created_at,
            expected_epoch,
            stale_retries + 1
          )

        {:error, :stale_revision} ->
          retry_exhausted(:append, stale_retries + 1)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp build_append_entry(log_id, writer_id, body, created_at, tips) do
    tip = Map.get(tips, writer_id)
    writer_seq = if tip, do: tip.seq + 1, else: 1

    raw =
      Jason.encode!(%{
        "version" => 1,
        "log_id" => log_id,
        "entry_id" => UUID.uuidv7(),
        "writer_id" => writer_id,
        "writer_seq" => writer_seq,
        "prev_entry_id" => if(tip, do: tip.entry_id, else: nil),
        "created_at" => encode_created_at(created_at),
        "body" => body
      })

    with {:ok, canonical_bytes} <- Entry.validate_entry(raw) do
      {:ok, batch_entry(canonical_bytes)}
    end
  end

  defp append_commit_plan(log_id, revision, expected_epoch, entry) do
    %CommitPlan{
      log_id: log_id,
      expected_revision: revision,
      expected_epoch: expected_epoch,
      insert_entries: [insert_row(entry)],
      put_tips: [tip_row(entry)]
    }
  end

  defp validate_batch(raw_entries, log_id) do
    Enum.reduce_while(raw_entries, {:ok, []}, fn raw, {:ok, entries} ->
      case validate_incoming(raw, log_id) do
        {:ok, entry} -> {:cont, {:ok, [entry | entries]}}
        {:error, _code, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp validate_incoming(raw, log_id) when is_binary(raw) do
    with {:ok, canonical_bytes} <- Entry.validate_entry(raw),
         entry = batch_entry(canonical_bytes),
         :ok <- check_log_id(entry.log_id, log_id) do
      {:ok, entry}
    end
  end

  defp validate_incoming(_raw, _log_id), do: {:error, "invalid_entry", "entry-not-bytes"}

  defp check_log_id(log_id, log_id), do: :ok

  defp check_log_id(_entry_log_id, _target_log_id),
    do: {:error, "invalid_entry", "log-id-mismatch"}

  defp retry_merge(persistence_mod, store, log_id, batch, stale_retries) do
    query = read_query(batch)

    with {:ok, read_set} <- persistence_mod.read_set(store, log_id, query),
         outcome <- classify(batch, read_set),
         {:ok, merge_plan} <- outcome do
      insert_entries = Enum.flat_map(merge_plan.per_writer, & &1.new_entries)

      if insert_entries == [] do
        {:ok, %{inserted: 0, present: merge_plan.present_count, revision: read_set.revision}}
      else
        plan = %CommitPlan{
          log_id: log_id,
          expected_revision: read_set.revision,
          expected_epoch: read_set.lease_epoch,
          insert_entries: Enum.map(insert_entries, &insert_row/1),
          put_tips: Enum.map(merge_plan.per_writer, &tip_row(List.last(&1.new_entries)))
        }

        case persistence_mod.commit(store, plan) do
          {:ok, revision} ->
            {:ok,
             %{
               inserted: length(insert_entries),
               present: merge_plan.present_count,
               revision: revision
             }}

          {:error, :stale_revision} when stale_retries < @max_stale_retries ->
            retry_merge(persistence_mod, store, log_id, batch, stale_retries + 1)

          {:error, :stale_revision} ->
            retry_exhausted(:merge, stale_retries + 1)

          {:error, _reason} = error ->
            error
        end
      end
    end
  end

  defp classify(batch, read_set) do
    present_by_coord = fn writer_id, writer_seq ->
      Map.get(read_set.coordinates, {writer_id, writer_seq})
    end

    present_by_id = fn entry_id ->
      case Map.get(read_set.entry_ids, entry_id) do
        nil ->
          nil

        canonical_bytes ->
          stored = batch_entry(canonical_bytes)

          %{
            writer_id: stored.writer_id,
            writer_seq: stored.writer_seq,
            bytes: canonical_bytes
          }
      end
    end

    MergePlan.plan_merge(batch, read_set.tips, present_by_coord, present_by_id)
  end

  defp read_query(batch) do
    %{
      writers: batch |> Enum.map(& &1.writer_id) |> Enum.uniq(),
      coordinates: batch |> Enum.map(&{&1.writer_id, &1.writer_seq}) |> Enum.uniq(),
      entry_ids: batch |> Enum.map(& &1.entry_id) |> Enum.uniq()
    }
  end

  defp batch_entry(canonical_bytes) do
    parsed = Jason.decode!(canonical_bytes)

    %{
      log_id: parsed["log_id"],
      entry_id: parsed["entry_id"],
      writer_id: parsed["writer_id"],
      writer_seq: parsed["writer_seq"],
      prev_entry_id: parsed["prev_entry_id"],
      created_at: parsed["created_at"],
      canonical_bytes: canonical_bytes
    }
  end

  defp insert_row(entry) do
    %{
      log_id: entry.log_id,
      entry_id: entry.entry_id,
      writer_id: entry.writer_id,
      writer_seq: entry.writer_seq,
      prev_entry_id: entry.prev_entry_id,
      created_at: entry.created_at,
      canonical_bytes: entry.canonical_bytes
    }
  end

  defp tip_row(entry) do
    %{writer_id: entry.writer_id, seq: entry.writer_seq, entry_id: entry.entry_id}
  end

  defp retry_exhausted(operation, attempts) do
    {:error, {:retry_exhausted, %{operation: operation, attempts: attempts}}}
  end

  defp resolve_epoch(:current, read_epoch), do: read_epoch
  defp resolve_epoch(expected_epoch, _read_epoch), do: expected_epoch

  defp encode_created_at(%DateTime{} = created_at), do: DateTime.to_iso8601(created_at)
  defp encode_created_at(created_at) when is_binary(created_at), do: created_at
end
