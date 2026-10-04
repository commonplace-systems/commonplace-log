defmodule Commonplace.Log.LocalSuffix do
  @moduledoc """
  The backend-PAGED local suffix read (CHECKPOINT-SNAP-1, Phase B round 3):
  exactly the entries strictly after a VERIFIED local frontier F, through an
  ending coordinate E captured when F is verified, without reading the prefix.

      {:ok, f} = LocalSuffix.local_frontier(log, applied_arrival)   # at capture
      ...
      {:ok, %{entries: rows, after: f_seq, through: e}} = LocalSuffix.read(log, f)

  `log` is a bound log `%{module: persistence_module, store: store, log_id: id}`
  (the shape `Commonplace.Log.Frontier` uses). The module must implement the
  optional `Commonplace.Log.Persistence` callbacks `local_frontier/3`,
  `open_local_suffix/3` and `read_local_page/5`; one that does not (the
  Cloudflare sidecar lane, today) answers `{:error, :local_suffix_unsupported}`
  and the caller replays in full.

  ## What `read/3` guarantees

    1. F is verified against the log first (`open_local_suffix/3`): same log,
       same incarnation, the same entry at F and the same per-writer prefix at
       F, recomputed from the log. A wrong, foreign or stale F is REFUSED with
       `{:error, {:local_frontier_refused, reason}}`; it is never read as an
       empty or shorter suffix.
    2. E is captured in the same read transaction as that verification.
       Entries are immutable and arrival coordinates are never reused, so the
       range `(F, E]` is fixed from then on: appends racing the read land
       after E and are simply not part of this result (a later read from E
       returns them).
    3. Pages are bounded range reads `(cursor, E]`; the prefix is never read.
    4. The result is checked before it is returned, against facts the log
       captured with E: strictly increasing arrival coordinates, all in
       `(F, E]`, ending exactly AT E unless empty (only `E == F`), and, WRITER
       BY WRITER, exactly the sequences `seq_w(F)+1 .. seq_w(E)` in order,
       contiguous, ending at the entry the log names as w's tip at E. A page
       source that skipped, repeated, reordered or leaked a row cannot pass:
       per-writer sequences are gapless, so every missing or extra row breaks
       some writer's run.

  Rows are `%{canonical_bytes, arrival_seq, operation_id, writer_id,
  writer_seq, entry_id}`: the `tail_local/3` row shape plus the stored
  coordinate columns.
  """

  alias Commonplace.Log.LocalFrontier

  defmodule Verified do
    @moduledoc """
    The result of `Commonplace.Log.LocalSuffix.verify/2`, OPAQUE to callers:
    bound to the log (`log_id`) and incarnation it was verified against.
    `read_verified/3` pages only for that log, after re-verifying F there.
    Read `applied`, `suffix_count` and `through`; never build one by hand.
    """
    @enforce_keys [:log_id, :incarnation, :frontier, :after, :through, :applied, :suffix_count, :writers_at_end]
    defstruct @enforce_keys
  end

  @default_page_size 500

  @type log :: %{module: module(), store: term(), log_id: String.t()}

  @doc "Whether `module` can serve verified local suffix reads."
  @spec supported?(module()) :: boolean()
  def supported?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :open_local_suffix, 3) and
      function_exported?(module, :read_local_page, 5) and
      function_exported?(module, :local_frontier, 3)
  end

  @doc "The verifiable local frontier through `arrival_seq` (see `Commonplace.Log.LocalFrontier`)."
  @spec local_frontier(log(), non_neg_integer()) :: {:ok, LocalFrontier.t()} | {:error, term()}
  def local_frontier(%{module: module, store: store, log_id: log_id}, arrival_seq) do
    if supported?(module),
      do: module.local_frontier(store, log_id, arrival_seq),
      else: {:error, :local_suffix_unsupported}
  end

  @doc """
  The VERIFY step alone (read-only, no row is paged): verifies `frontier`
  against the log exactly as `read/3` does and captures the ending coordinate
  E with every writer's tip at E, in the same read transaction.

  Returns `{:ok, verified}` with

      %{frontier: f, after: f.arrival_seq, through: e,
        applied: Σ seq_w(F), suffix_count: Σ seq_w(E) - Σ seq_w(F),
        writers_at_end: [...]}

  `applied` is the number of entries at or before F, counting ALL writers;
  `suffix_count` is exactly the number of entries in `(F, E]` (writer
  sequences are gapless and accepted in order), i.e. the length of the suffix
  `read_verified/3` will return. A caller can therefore decide whether the
  suffix is worth reading BEFORE reading it. Refusals are those of `read/3`.
  """
  @spec verify(log(), LocalFrontier.t()) :: {:ok, map()} | {:error, term()}
  def verify(%{module: module, store: store, log_id: log_id}, %LocalFrontier{} = frontier) do
    if supported?(module) do
      with {:ok, %{through: through, writers: at_end}} <- module.open_local_suffix(store, log_id, frontier) do
        applied = Enum.reduce(frontier.writers, 0, &(&1.seq + &2))

        {:ok,
         %Verified{
           log_id: log_id,
           incarnation: frontier.incarnation,
           frontier: frontier,
           after: frontier.arrival_seq,
           through: through,
           applied: applied,
           suffix_count: Enum.reduce(at_end, 0, &(&1.seq + &2)) - applied,
           writers_at_end: at_end
         }}
      end
    else
      {:error, :local_suffix_unsupported}
    end
  end

  @doc """
  Pages exactly the suffix a `verify/2` result names, `(F, E]`, and checks it
  (range, end, per-writer runs against the writers captured at E). Rows at or
  before E are immutable, so the range verified earlier is still the range
  read. Options: `:page_size` (default #{@default_page_size}).

  The value is BOUND to the log it was verified against: anything but a
  `%Verified{}` is `{:error, {:local_suffix_inconsistent, :malformed_verified}}`;
  a value for another log is `{:local_frontier_refused, :log_mismatch}`; and F
  is re-verified on THIS log (incarnation, entry, per-writer prefix; a few
  index probes) before any page is read, so a foreign or stale value -- even
  one naming an empty suffix -- is refused, never answered as empty.
  """
  @spec read_verified(log(), Verified.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read_verified(log, verified, opts \\ [])

  def read_verified(%{module: module, store: store, log_id: log_id}, %Verified{} = verified, opts) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    %Verified{frontier: frontier, through: through, writers_at_end: at_end} = verified

    cond do
      not supported?(module) ->
        {:error, :local_suffix_unsupported}

      not (is_integer(page_size) and page_size > 0) ->
        {:error, {:invalid_page_size, page_size}}

      not well_formed?(verified) ->
        {:error, {:local_suffix_inconsistent, :malformed_verified}}

      verified.log_id != log_id ->
        {:error, {:local_frontier_refused, :log_mismatch}}

      true ->
        with :ok <- reverify(module, store, log_id, verified),
             {:ok, rows, pages} <-
               pages(module, store, log_id, frontier.arrival_seq, through, page_size, [], 0),
             :ok <- check_range(rows, frontier.arrival_seq, through),
             :ok <- check_writers(rows, frontier.writers, at_end) do
          {:ok, %{entries: rows, after: frontier.arrival_seq, through: through, pages: pages}}
        end
    end
  end

  def read_verified(_log, _verified, _opts),
    do: {:error, {:local_suffix_inconsistent, :malformed_verified}}

  defp well_formed?(%Verified{} = v) do
    LocalFrontier.validate(v.frontier) == :ok and v.incarnation == v.frontier.incarnation and
      v.log_id == v.frontier.log_id and is_integer(v.through) and v.through >= v.frontier.arrival_seq and
      is_list(v.writers_at_end)
  end

  # F re-verified on this log; E can only have grown since (same incarnation).
  defp reverify(module, store, log_id, %Verified{frontier: f, through: through}) do
    case module.open_local_suffix(store, log_id, f) do
      {:ok, %{through: now}} when now >= through -> :ok
      {:ok, _} -> {:error, {:local_frontier_refused, :beyond_end}}
      {:error, _} = error -> error
    end
  end

  @doc """
  Reads the verified suffix after `frontier`: `verify/2` then
  `read_verified/3`. Options: `:page_size` (default #{@default_page_size}).
  Returns `{:ok, %{entries: rows, after: f, through: e, pages: n}}` or an error.
  """
  @spec read(log(), LocalFrontier.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def read(log, %LocalFrontier{} = frontier, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, @default_page_size)

    cond do
      not supported?(log.module) ->
        {:error, :local_suffix_unsupported}

      not (is_integer(page_size) and page_size > 0) ->
        {:error, {:invalid_page_size, page_size}}

      true ->
        with {:ok, verified} <- verify(log, frontier), do: read_verified(log, verified, opts)
    end
  end

  defp pages(module, store, log_id, cursor, through, page_size, acc, n) do
    case module.read_local_page(store, log_id, cursor, through, page_size) do
      {:ok, %{entries: page, next_after_arrival: nil}} ->
        {:ok, Enum.concat(Enum.reverse([page | acc])), n + 1}

      {:ok, %{entries: page, next_after_arrival: next}} when is_integer(next) and next > cursor ->
        pages(module, store, log_id, next, through, page_size, [page | acc], n + 1)

      {:ok, %{next_after_arrival: next}} ->
        {:error, {:local_suffix_inconsistent, {:cursor_not_advancing, cursor, next}}}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # Writer by writer, the suffix rows must be exactly seq_w(F)+1 .. seq_w(E),
  # in order, ending at w's tip entry at E. Public for the proof.
  def check_writers(rows, writers_at_f, writers_at_e) do
    from = Map.new(writers_at_f, &{&1.writer_id, &1.seq})

    with {:ok, by_writer} <- group_rows(rows) do
      expected_writers =
        for %{writer_id: w, seq: tip} <- writers_at_e, tip > Map.get(from, w, 0), into: %{}, do: {w, tip}

      cond do
        MapSet.new(Map.keys(by_writer)) != MapSet.new(Map.keys(expected_writers)) ->
          {:error, {:local_suffix_inconsistent, :writer_set}}

        not Enum.all?(writers_at_e, fn %{writer_id: w, seq: tip, entry_id: id} ->
               case Map.fetch(by_writer, w) do
                 :error ->
                   tip <= Map.get(from, w, 0)

                 {:ok, run} ->
                   Enum.map(run, &elem(&1, 0)) == Enum.to_list((Map.get(from, w, 0) + 1)..tip//1) and
                     elem(List.last(run), 1) == id
               end
             end) ->
          {:error, {:local_suffix_inconsistent, :writer_run}}

        true ->
          :ok
      end
    end
  end

  # Rows carry their stored coordinate columns (`read_local_page/5`); no JSON
  # is decoded here. A row without them is refused, never guessed.
  defp group_rows(rows) do
    rows
    |> Enum.reduce_while({:ok, %{}}, fn
      %{writer_id: w, writer_seq: seq, entry_id: id}, {:ok, acc} when is_binary(w) and is_integer(seq) ->
        {:cont, {:ok, Map.update(acc, w, [{seq, id}], &[{seq, id} | &1])}}

      _row, _acc ->
        {:halt, {:error, {:local_suffix_inconsistent, :unreadable_row}}}
    end)
    |> case do
      {:ok, acc} -> {:ok, Map.new(acc, fn {w, run} -> {w, Enum.reverse(run)} end)}
      error -> error
    end
  end

  @doc false
  # The result check, public so the proof can show it refuses each defect shape.
  def check_range(rows, after_seq, through) do
    arrivals = Enum.map(rows, & &1.arrival_seq)

    cond do
      Enum.any?(arrivals, &(&1 <= after_seq or &1 > through)) ->
        {:error, {:local_suffix_inconsistent, :out_of_range}}

      arrivals != Enum.sort(Enum.uniq(arrivals)) ->
        {:error, {:local_suffix_inconsistent, :not_strictly_increasing}}

      through > after_seq and List.last(arrivals) != through ->
        {:error, {:local_suffix_inconsistent, :short_of_end}}

      true ->
        :ok
    end
  end
end
