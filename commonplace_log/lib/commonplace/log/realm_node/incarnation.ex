defmodule Commonplace.Log.RealmNode.Incarnation do
  @moduledoc false

  use GenServer

  alias Commonplace.Log.UUID

  def start_link(state), do: GenServer.start_link(__MODULE__, state, name: __MODULE__)

  def mint do
    %{
      incarnation_id: UUID.uuidv7(),
      booted_at: DateTime.utc_now() |> DateTime.to_iso8601()
    }
  end

  def current, do: GenServer.call(__MODULE__, :current)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:current, _from, state), do: {:reply, state, state}
end
