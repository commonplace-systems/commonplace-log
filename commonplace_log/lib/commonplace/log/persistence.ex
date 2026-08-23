defmodule Commonplace.Log.Persistence do
  @moduledoc """
  Storage boundary used by the normative log engine.

  A read set is a coherent snapshot containing only the rows named by its
  query. `ReadSet.entry_ids` maps an entry ID directly to canonical bytes;
  it never contains parsed fields or coordinates. When identity
  classification needs the stored coordinate, the Engine parses those
  canonical bytes itself. Parsing and domain classification never move to
  the adapter side.

  A read set also carries the durable lease epoch observed in that snapshot.
  `take_lease/2` atomically advances that epoch and returns the new value.
  Every commit supplies both its expected revision and expected epoch; revision
  mismatch is retryable `:stale_revision`, while an obsolete writer is rejected
  distinctly as `:obsolete_epoch`.

  Commit-plan insertion rows supply the `entry_id`, `writer_id`, `writer_seq`,
  `prev_entry_id`, and `created_at` columns, plus `canonical_bytes` for the
  `canonical_json` column.
  Replica-local arrival metadata such as `received_at_ms` and `arrival_seq`
  is assigned by the adapter and must never be carried in a `CommitPlan`.
  That metadata is outside entry identity and merge semantics.

  The caller-visible read shapes are deliberately pinned here. A former
  `map()` return type allowed two adapters to diverge, while the sync engine
  depends on the continuation cursors to consume complete ranges.

    * `frontier/2` returns `%{writers: writers}`, where every writer is a
      `%{writer_id: ..., seq: ..., entry_id: ...}` map and `writers` is sorted
      by `writer_id`.
    * `read_writer/4` returns `%{entries: entries, next_after_seq: cursor}`.
      The cursor key is mandatory; its value is the last returned sequence
      when another page exists, and `nil` when the requested range is
      exhausted.
    * `tail_local/3` returns
      `%{entries: entries, next_after_arrival: cursor}`. The cursor key is
      mandatory; its value is the last returned arrival sequence when
      another page exists, and `nil` when the requested range is exhausted.
  """

  defmodule ReadSet do
    @moduledoc "A coherent persistence snapshot requested by the Engine."

    @type tip :: %{seq: pos_integer(), entry_id: String.t()}

    @type t :: %__MODULE__{
            log_id: String.t(),
            revision: non_neg_integer(),
            lease_epoch: non_neg_integer(),
            tips: %{optional(String.t()) => tip()},
            coordinates: %{{String.t(), pos_integer()} => binary()},
            entry_ids: %{optional(String.t()) => binary()}
          }

    @enforce_keys [:log_id, :revision, :lease_epoch]
    defstruct log_id: nil,
              revision: 0,
              lease_epoch: 0,
              tips: %{},
              coordinates: %{},
              entry_ids: %{}
  end

  defmodule CommitPlan do
    @moduledoc "An Engine-authored atomic write plan guarded by revision and lease epoch."

    @type insert_entry :: %{
            log_id: String.t(),
            entry_id: String.t(),
            writer_id: String.t(),
            writer_seq: pos_integer(),
            prev_entry_id: String.t() | nil,
            created_at: String.t(),
            canonical_bytes: binary()
          }

    @type put_tip :: %{writer_id: String.t(), seq: pos_integer(), entry_id: String.t()}

    @type t :: %__MODULE__{
            log_id: String.t(),
            expected_revision: non_neg_integer(),
            expected_epoch: non_neg_integer(),
            insert_entries: [insert_entry()],
            put_tips: [put_tip()]
          }

    @enforce_keys [:log_id, :expected_revision, :expected_epoch]
    defstruct log_id: nil,
              expected_revision: 0,
              expected_epoch: 0,
              insert_entries: [],
              put_tips: []
  end

  @typedoc "The adapter-specific store handle."
  @type store :: term()

  @typedoc "A query naming exactly the state needed for one Engine decision."
  @type read_query :: %{
          required(:writers) => [String.t()],
          required(:coordinates) => [{String.t(), pos_integer()}],
          required(:entry_ids) => [String.t()]
        }

  @typedoc "One writer tip in the writer-id-sorted frontier."
  @type frontier_writer :: %{
          writer_id: String.t(),
          seq: pos_integer(),
          entry_id: String.t()
        }

  @typedoc "The complete frontier, whose writers are sorted by writer_id."
  @type frontier :: %{writers: [frontier_writer()]}

  @typedoc "One canonical entry in a writer-range page."
  @type writer_entry :: %{canonical_bytes: binary(), writer_seq: pos_integer()}

  @typedoc "A writer-range page. The continuation key is always present."
  @type writer_page :: %{
          entries: [writer_entry()],
          next_after_seq: pos_integer() | nil
        }

  @typedoc "One canonical entry in replica-local arrival order."
  @type local_entry :: %{canonical_bytes: binary(), arrival_seq: pos_integer()}

  @typedoc "A local-tail page. The continuation key is always present."
  @type local_page :: %{
          entries: [local_entry()],
          next_after_arrival: pos_integer() | nil
        }

  @callback create_log(store(), log_id :: String.t(), metadata :: map()) ::
              :ok | {:error, term()}

  @doc "Atomically advance a log's durable lease epoch and return the new epoch."
  @callback take_lease(store(), log_id :: String.t()) ::
              {:ok, new_epoch :: pos_integer()} | {:error, term()}

  @callback read_set(store(), log_id :: String.t(), read_query()) ::
              {:ok, ReadSet.t()} | {:error, term()}

  @callback commit(store(), CommitPlan.t()) ::
              {:ok, new_revision :: non_neg_integer()}
              | {:error, :stale_revision | :obsolete_epoch | term()}

  @callback frontier(store(), log_id :: String.t()) :: {:ok, frontier()} | {:error, term()}

  @callback read_writer(store(), log_id :: String.t(), writer_id :: String.t(), keyword()) ::
              {:ok, writer_page()} | {:error, term()}

  @callback tail_local(store(), log_id :: String.t(), keyword()) ::
              {:ok, local_page()} | {:error, term()}
end
