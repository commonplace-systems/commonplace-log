defmodule Commonplace.Log.Persistence do
  @moduledoc """
  Storage boundary used by the normative log engine.

  A read set is a coherent snapshot containing only the rows named by its
  query. `ReadSet.entry_ids` maps an entry ID directly to canonical bytes;
  it never contains parsed fields or coordinates. When identity
  classification needs the stored coordinate, the Engine parses those
  canonical bytes itself. Parsing and domain classification never move to
  the adapter side.

  Commit-plan insertion rows supply the `entry_id`, `writer_id`, `writer_seq`,
  `prev_entry_id`, and `created_at` columns, plus `canonical_bytes` for the
  `canonical_json` column.
  Replica-local arrival metadata such as `received_at_ms` and `arrival_seq`
  is assigned by the adapter and must never be carried in a `CommitPlan`.
  That metadata is outside entry identity and merge semantics.
  """

  defmodule ReadSet do
    @moduledoc "A coherent persistence snapshot requested by the Engine."

    @type tip :: %{seq: pos_integer(), entry_id: String.t()}

    @type t :: %__MODULE__{
            log_id: String.t(),
            revision: non_neg_integer(),
            tips: %{optional(String.t()) => tip()},
            coordinates: %{{String.t(), pos_integer()} => binary()},
            entry_ids: %{optional(String.t()) => binary()}
          }

    @enforce_keys [:log_id, :revision]
    defstruct log_id: nil, revision: 0, tips: %{}, coordinates: %{}, entry_ids: %{}
  end

  defmodule CommitPlan do
    @moduledoc "An Engine-authored atomic write plan guarded by a revision."

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
            insert_entries: [insert_entry()],
            put_tips: [put_tip()]
          }

    @enforce_keys [:log_id, :expected_revision]
    defstruct log_id: nil, expected_revision: 0, insert_entries: [], put_tips: []
  end

  @typedoc "The adapter-specific store handle."
  @type store :: term()

  @typedoc "A query naming exactly the state needed for one Engine decision."
  @type read_query :: %{
          required(:writers) => [String.t()],
          required(:coordinates) => [{String.t(), pos_integer()}],
          required(:entry_ids) => [String.t()]
        }

  @callback create_log(store(), log_id :: String.t(), metadata :: map()) ::
              :ok | {:error, term()}

  @callback read_set(store(), log_id :: String.t(), read_query()) ::
              {:ok, ReadSet.t()} | {:error, term()}

  @callback commit(store(), CommitPlan.t()) ::
              {:ok, new_revision :: non_neg_integer()}
              | {:error, :stale_revision | term()}

  @callback frontier(store(), log_id :: String.t()) :: {:ok, map()} | {:error, term()}

  @callback read_writer(store(), log_id :: String.t(), writer_id :: String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback tail_local(store(), log_id :: String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
