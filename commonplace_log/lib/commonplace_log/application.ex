defmodule CommonplaceLog.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    incarnation = Commonplace.Log.RealmNode.Incarnation.mint()

    children =
      [
        {Commonplace.Log.RealmNode.Incarnation, incarnation},
        {Registry, keys: :unique, name: Commonplace.LogStore.SQLite.Registry},
        {DynamicSupervisor,
         strategy: :one_for_one, name: Commonplace.LogStore.SQLite.DynamicSupervisor}
      ] ++ realm_http_children()

    Supervisor.start_link(children, strategy: :one_for_one, name: CommonplaceLog.Supervisor)
  end

  defp realm_http_children do
    case System.get_env("COMMONPLACE_REALM_HTTP_PORT") do
      nil ->
        []

      value ->
        port =
          Application.get_env(:commonplace_log, Commonplace.Log.RealmNode, [])
          |> Keyword.get(:http_port, value)
          |> parse_port!()

        [
          {Bandit,
           plug: Commonplace.Log.RealmNode,
           scheme: :http,
           ip: {0, 0, 0, 0},
           port: port,
           thousand_island_options: [
             supervisor_options: [name: Commonplace.Log.RealmNode.HTTP]
           ]}
        ]
    end
  end

  defp parse_port!(value) when is_binary(value) do
    case Integer.parse(value) do
      {port, ""} when port in 1..65_535 -> port
      _ -> raise "COMMONPLACE_REALM_HTTP_PORT must be an integer from 1 to 65535"
    end
  end

  defp parse_port!(port) when port in 1..65_535, do: port
end
