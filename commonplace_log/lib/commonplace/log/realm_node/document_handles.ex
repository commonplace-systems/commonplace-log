defmodule Commonplace.Log.RealmNode.DocumentHandles do
  @moduledoc false

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(log_id, handle), do: Agent.update(__MODULE__, &Map.put(&1, log_id, handle))
  def fetch(log_id), do: Agent.get(__MODULE__, &Map.fetch(&1, log_id))
  def delete(log_id), do: Agent.update(__MODULE__, &Map.delete(&1, log_id))
  def clear, do: Agent.update(__MODULE__, fn _handles -> %{} end)
end
