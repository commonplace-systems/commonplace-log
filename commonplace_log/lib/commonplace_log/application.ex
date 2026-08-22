defmodule CommonplaceLog.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Registry, keys: :unique, name: Commonplace.LogStore.SQLite.Registry},
      {DynamicSupervisor,
       strategy: :one_for_one, name: Commonplace.LogStore.SQLite.DynamicSupervisor}
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: CommonplaceLog.Supervisor)
  end
end
