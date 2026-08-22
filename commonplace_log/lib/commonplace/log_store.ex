defmodule Commonplace.LogStore do
  @moduledoc """
  The storage behavior from spec §14 ("Elixir interface",
  `docs/commonplace-monotonic-log-spec.md`): the application depends on this
  behavior rather than directly on CubDB, SQLite, or HTTP.

  Ported verbatim from the §14 `defmodule` block with ONE recorded delta: the
  spec writes identifier typespecs as `Ecto.UUID.t()`, but this project takes
  no Ecto dependency (SP1 decision, carried through the SP3 plan's tech-stack
  note), so every `Ecto.UUID.t()` is written here as `String.t()`.
  `Ecto.UUID.t()` is itself defined as `String.t()` (a UUID in its canonical
  textual representation), so the delta is name-only — no shape change.
  Callback names, arities, argument order, and result shapes are otherwise
  exactly the spec's.

  Known adapters (spec §14 "Recommended adapters"):

    * `Commonplace.LogStore.SQLite` — a host with durable local disk (SP3);
    * `Commonplace.LogStore.Cloudflare` — HTTP access from a BEAM Container
      (SP4);
    * `Commonplace.LogStore.CubDB` — migration adapter for the existing
      system (future).
  """

  @callback create_log(log_id :: String.t()) :: :ok | {:error, term()}

  @callback append(
              log_id :: String.t(),
              writer_id :: String.t(),
              body :: map(),
              created_at :: DateTime.t()
            ) :: {:ok, map()} | {:error, term()}

  @callback merge(log_id :: String.t(), entries :: [map()]) ::
              {:ok, map()} | {:error, term()}

  @callback frontier(log_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @callback read_writer(
              log_id :: String.t(),
              writer_id :: String.t(),
              keyword()
            ) :: {:ok, map()} | {:error, term()}

  @callback tail_local(log_id :: String.t(), keyword()) ::
              {:ok, map()} | {:error, term()}
end
