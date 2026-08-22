defmodule Commonplace.Log.MergePlan do
  @moduledoc """
  Pure merge classification per spec §9.3 (rules 1–6 and the three merge
  error codes), §6.3 (entry-ID collision), §8 invariants 3/4/9/10.

  **Authority status (BEAM-native revision, `docs/proposals/2026-08-22-beam-native-revision.md`):
  this module is the NORMATIVE implementation of merge classification.**
  `worker/src/do/merge-plan.ts` is an independent conforming workalike
  verified against it by shared fixtures and black-box equivalence (a
  200-scenario differential, seed 424242, ran at porting time with 0
  mismatches), not by source-level lockstep. A behavioral change here is a
  protocol change: it must be deliberate, spec-grounded, and reflected in
  the shared conformance material the workalike is checked against.
  Historical note: this module began as a behavior-for-behavior port OF the
  TS side (test table row names still match), and the direction of
  authority reversed with the revision.

  This module is a pure function over already-validated, canonicalized
  entries: no database, no I/O. The store executes the returned plan inside
  one transaction; execution concerns stay out of here. An error outcome
  refuses the WHOLE batch — it carries no per-writer plan, so no partial
  write can be derived from it (invariant 10).

  ## Wire mapping for `:invalid_batch`

  `:invalid_batch` is an internal-only code — §11.6 has no "invalid_batch".
  Wire mapping: 422 `invalid_entry` (an intra-batch prev-linkage violation
  breaks §7's relational requirement between consecutive entries; the batch
  is malformed as submitted, unlike gap/fork which are receiver-state
  conflicts).

  ## The eight reviewed interpretation decisions (shared with the TS workalike)

  1. An error outcome refuses the whole batch and carries no per-writer
     plan, so no partial write can be derived from it (§8 invariant 10).
  2. Deterministic processing order: writers sorted by `writer_id`; the
     first failing writer's error is the batch's error. (`writer_id` MUST
     be a UUID per §7, i.e. ASCII, so JS UTF-16 code-unit sort and Elixir
     byte sort agree.)
  3. The intra-batch `entry_id` registry is global across writers
     (§8 invariant 4), threaded through the whole batch.
  4. §6.3: an `entry_id` reused for different bytes (or a different
     coordinate, which implies different bytes) MUST be rejected as a
     collision, whether the prior owner is in the store or earlier in this
     batch — and the identity check runs BEFORE the coordinate checks, so
     a same-coordinate tampered reuse is a collision, not a fork. An exact
     repeat (same id, same coordinate, byte-equal) is deduplicated and its
     copy counted as present.
  5. Two distinct entries at one coordinate inside the batch: the
     coordinate can hold at most one entry (§8 invariant 3), so the batch
     itself contains a fork → `:writer_fork`.
  6. §9.3 rule 2: at or below the tip, an exact byte-equal duplicate of the
     stored entry is present; anything else at an occupied coordinate is a
     fork. A `nil` coordinate lookup at/below the tip is a store
     inconsistency (invariant 5 says it is occupied); classify it like a
     mismatch rather than inventing an insert over unknown state.
  7. §9.3 rules 3–4: the first new entry is exactly `tip + 1` (else
     `:writer_gap` carrying the receiver's tip) and its `prev_entry_id`
     equals the local tip's entry id (`nil` for a fresh writer's entry 1).
     A prev mismatch at the right sequence means the coordinate would hold
     a different chain: `:writer_fork`.
  8. §9.3 rule 5: every subsequent entry increments by one — a hole after
     the first new entry is a gap AT THE HOLE — and names the preceding
     batch entry — a wrong link is intra-batch incoherence,
     `:invalid_batch` (see the wire-mapping note above).
  """

  @typedoc "A writer's current local tip as known to the store."
  @type tip_info :: %{seq: pos_integer(), entry_id: String.t()}

  @typedoc "One validated batch entry: parsed fields plus its canonical bytes."
  @type batch_entry :: %{
          entry_id: String.t(),
          writer_id: String.t(),
          writer_seq: pos_integer(),
          prev_entry_id: String.t() | nil,
          canonical_bytes: binary()
        }

  @typedoc """
  One plan per writer with new entries, sorted by `writer_id`. Writers whose
  batch entries were all already present are omitted.
  """
  @type writer_plan :: %{
          writer_id: String.t(),
          first_new_seq: pos_integer(),
          new_entries: [batch_entry()]
        }

  @typedoc "The stored entry owning an entry_id, as returned by `present_by_id`."
  @type stored_entry :: %{
          writer_id: String.t(),
          writer_seq: pos_integer(),
          bytes: binary()
        }

  @typedoc """
  Classification outcome. `present_count` counts entries accepted as already
  present (§9.3 rule 2) plus exact intra-batch duplicates, so inserted +
  present covers the batch.
  """
  @type outcome ::
          {:ok, %{per_writer: [writer_plan()], present_count: non_neg_integer()}}
          | {:error,
             {:writer_gap,
              %{
                writer_id: String.t(),
                expected_seq: pos_integer(),
                tip_entry_id: String.t() | nil
              }}}
          | {:error, {:writer_fork, %{writer_id: String.t(), seq: pos_integer()}}}
          | {:error, {:entry_id_collision, %{entry_id: String.t()}}}
          | {:error, {:invalid_batch, %{reason: String.t()}}}

  @doc """
  Classify a validated batch against the store's current per-writer tips.

    * `batch` — validated entries (any order; §9.3 rule 1 sorting is ours).
    * `existing` — per-writer tips known to the store; absent = fresh writer.
    * `present_by_coord` — canonical bytes already stored at `(writer, seq)`,
      or `nil` when the coordinate is unoccupied.
    * `present_by_id` — stored entry owning an entry_id, or `nil`.
  """
  @spec plan_merge(
          [batch_entry()],
          %{String.t() => tip_info()},
          (String.t(), pos_integer() -> binary() | nil),
          (String.t() -> stored_entry() | nil)
        ) :: outcome()
  def plan_merge(batch, existing, present_by_coord, present_by_id) do
    by_writer = Enum.group_by(batch, & &1.writer_id)

    # Deterministic processing order: writers sorted by writer_id. The first
    # failing writer's error is the batch's error.
    writer_ids = by_writer |> Map.keys() |> Enum.sort()

    # Intra-batch entry_id registry (`seen_ids`), global across writers
    # (§8 invariant 4), threaded through the fold.
    writer_ids
    |> Enum.reduce_while({%{}, [], 0}, fn writer_id, {seen_ids, per_writer, present_count} ->
      # §9.3 rule 1: sort entries by writer_seq (stable, like the TS twin).
      entries = by_writer |> Map.fetch!(writer_id) |> Enum.sort_by(& &1.writer_seq)

      tip = Map.get(existing, writer_id)
      tip_seq = if tip, do: tip.seq, else: 0
      tip_entry_id = if tip, do: tip.entry_id, else: nil

      with {:ok, seen_ids, deduped, dup_present} <-
             pass1(entries, writer_id, seen_ids, present_by_id, [], 0),
           {:ok, new_entries, seg_present} <-
             pass2(deduped, writer_id, tip_seq, tip_entry_id, present_by_coord, [], 0) do
        per_writer =
          if new_entries == [] do
            per_writer
          else
            per_writer ++
              [%{writer_id: writer_id, first_new_seq: tip_seq + 1, new_entries: new_entries}]
          end

        {:cont, {seen_ids, per_writer, present_count + dup_present + seg_present}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:error, _} = error ->
        error

      {_seen_ids, per_writer, present_count} ->
        {:ok, %{per_writer: per_writer, present_count: present_count}}
    end
  end

  # Pass 1 — identity checks and intra-batch deduplication.
  # §6.3: an entry_id reused for different bytes (or a different coordinate,
  # which implies different bytes) MUST be rejected as a collision, whether
  # the prior owner is in the store or earlier in this batch. An exact repeat
  # (same id, same coordinate, byte-equal) is deduplicated and its copy
  # counted as present. Accumulates `deduped` in reverse.
  defp pass1([], _writer_id, seen_ids, _present_by_id, deduped_rev, present) do
    {:ok, seen_ids, Enum.reverse(deduped_rev), present}
  end

  defp pass1([entry | rest], writer_id, seen_ids, present_by_id, deduped_rev, present) do
    case Map.get(seen_ids, entry.entry_id) do
      %{} = prior ->
        if prior.writer_id == entry.writer_id and
             prior.writer_seq == entry.writer_seq and
             prior.canonical_bytes == entry.canonical_bytes do
          pass1(rest, writer_id, seen_ids, present_by_id, deduped_rev, present + 1)
        else
          {:error, {:entry_id_collision, %{entry_id: entry.entry_id}}}
        end

      nil ->
        stored = present_by_id.(entry.entry_id)

        if stored != nil and
             (stored.writer_id != entry.writer_id or
                stored.writer_seq != entry.writer_seq or
                stored.bytes != entry.canonical_bytes) do
          {:error, {:entry_id_collision, %{entry_id: entry.entry_id}}}
        else
          seen_ids = Map.put(seen_ids, entry.entry_id, entry)

          # Two distinct entries at one coordinate inside the batch: the
          # coordinate can hold at most one entry (§8 invariant 3), so the
          # batch itself contains a fork. Exact repeats were consumed above,
          # and after sorting equal seqs are adjacent.
          case deduped_rev do
            [last | _] when last.writer_seq == entry.writer_seq ->
              {:error, {:writer_fork, %{writer_id: writer_id, seq: entry.writer_seq}}}

            _ ->
              pass1(rest, writer_id, seen_ids, present_by_id, [entry | deduped_rev], present)
          end
        end
    end
  end

  # Pass 2 — classify present vs new; chain-check the new segment.
  # Accumulates `new_entries` in reverse (its head is the preceding entry).
  defp pass2([], _writer_id, _tip_seq, _tip_entry_id, _present_by_coord, new_rev, present) do
    {:ok, Enum.reverse(new_rev), present}
  end

  defp pass2(
         [entry | rest],
         writer_id,
         tip_seq,
         tip_entry_id,
         present_by_coord,
         new_rev,
         present
       ) do
    cond do
      entry.writer_seq <= tip_seq ->
        # §9.3 rule 2: an exact duplicate of a stored entry is present.
        # Anything else at an occupied coordinate is a fork. A coordinate
        # at or below the tip is occupied by invariant 5, so a nil lookup
        # is a store inconsistency; classify it like a mismatch rather
        # than inventing an insert over unknown state.
        stored_bytes = present_by_coord.(writer_id, entry.writer_seq)

        if stored_bytes == nil or stored_bytes != entry.canonical_bytes do
          {:error, {:writer_fork, %{writer_id: writer_id, seq: entry.writer_seq}}}
        else
          pass2(rest, writer_id, tip_seq, tip_entry_id, present_by_coord, new_rev, present + 1)
        end

      new_rev == [] ->
        cond do
          # §9.3 rule 3: the first new entry is exactly one after the tip.
          entry.writer_seq != tip_seq + 1 ->
            {:error,
             {:writer_gap,
              %{writer_id: writer_id, expected_seq: tip_seq + 1, tip_entry_id: tip_entry_id}}}

          # §9.3 rule 4: its prev_entry_id equals the local tip UUID (nil
          # for a fresh writer's entry 1). A mismatch at the right sequence
          # means the coordinate would hold a different chain: writer_fork.
          entry.prev_entry_id != tip_entry_id ->
            {:error, {:writer_fork, %{writer_id: writer_id, seq: entry.writer_seq}}}

          true ->
            pass2(
              rest,
              writer_id,
              tip_seq,
              tip_entry_id,
              present_by_coord,
              [entry | new_rev],
              present
            )
        end

      true ->
        [preceding | _] = new_rev

        cond do
          # §9.3 rule 5: every subsequent entry increments by one — a hole
          # after the first new entry is a gap at the hole —
          entry.writer_seq != preceding.writer_seq + 1 ->
            {:error,
             {:writer_gap,
              %{
                writer_id: writer_id,
                expected_seq: preceding.writer_seq + 1,
                tip_entry_id: tip_entry_id
              }}}

          # — and names the preceding batch entry — a wrong link is
          # intra-batch incoherence.
          entry.prev_entry_id != preceding.entry_id ->
            {:error,
             {:invalid_batch,
              %{
                reason:
                  "writer #{writer_id} seq #{entry.writer_seq}: prev_entry_id " <>
                    "does not name the preceding batch entry"
              }}}

          true ->
            pass2(
              rest,
              writer_id,
              tip_seq,
              tip_entry_id,
              present_by_coord,
              [entry | new_rev],
              present
            )
        end
    end
  end
end
