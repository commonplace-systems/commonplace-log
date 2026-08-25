defmodule Commonplace.Log.DocumentProfile.Lane do
  @moduledoc false

  @type activation :: %{
          required(:log_id) => String.t(),
          required(:writer_id) => String.t(),
          required(:lease) => non_neg_integer(),
          required(:adapter) => module(),
          required(:store) => term()
        }

  @callback create_log(String.t(), term()) :: :ok | {:error, term()}
  @callback open_log(String.t(), term()) :: :ok | {:error, term()}
  @callback activate(String.t(), term()) :: {:ok, activation()} | {:error, term()}
  @callback writer_id(map()) :: {:ok, String.t()} | {:error, term()}
  @callback frontier(map()) :: {:ok, Commonplace.Log.Persistence.frontier()} | {:error, term()}
  @callback read_writer(map(), keyword()) ::
              {:ok, Commonplace.Log.Persistence.writer_page()} | {:error, term()}
  @callback append_with_epoch(map(), map(), DateTime.t() | String.t(), non_neg_integer()) ::
              {:ok, map()} | {:error, term()} | {:error, String.t(), String.t()}
  @callback merge_with_epoch(map(), [binary()], non_neg_integer()) ::
              {:ok, map()} | {:error, term()} | {:error, String.t(), String.t()}

  def validate_lane(%{writers: []}, _writer_id), do: :ok
  def validate_lane(%{writers: [%{writer_id: writer_id}]}, writer_id), do: :ok

  def validate_lane(%{writers: writers}, _writer_id) do
    {:error, {:multiwriter_document_unsupported, %{writer_count: length(writers)}}}
  end
end
