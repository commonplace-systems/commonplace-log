defmodule Commonplace.Log.Test.BrokenEpochPersistence do
  @moduledoc "Deliberate contract mutation: commit ignores expected_epoch."
  @behaviour Commonplace.Log.Persistence

  alias Commonplace.Log.Test.InMemoryPersistence

  def create_log(store, log_id, metadata),
    do: InMemoryPersistence.create_log(store, log_id, metadata)

  def take_lease(store, log_id), do: InMemoryPersistence.take_lease(store, log_id)
  def read_set(store, log_id, query), do: InMemoryPersistence.read_set(store, log_id, query)

  def commit(store, plan) do
    current_epoch = InMemoryPersistence.snapshot(store, plan.log_id).lease_epoch
    InMemoryPersistence.commit(store, %{plan | expected_epoch: current_epoch})
  end

  def frontier(store, log_id), do: InMemoryPersistence.frontier(store, log_id)

  def read_writer(store, log_id, writer_id, opts),
    do: InMemoryPersistence.read_writer(store, log_id, writer_id, opts)

  def tail_local(store, log_id, opts), do: InMemoryPersistence.tail_local(store, log_id, opts)
end

defmodule Commonplace.Log.Test.BrokenRevisionPersistence do
  @moduledoc "Deliberate contract mutation: commit ignores expected_revision."
  @behaviour Commonplace.Log.Persistence

  alias Commonplace.Log.Test.InMemoryPersistence

  def create_log(store, log_id, metadata),
    do: InMemoryPersistence.create_log(store, log_id, metadata)

  def take_lease(store, log_id), do: InMemoryPersistence.take_lease(store, log_id)
  def read_set(store, log_id, query), do: InMemoryPersistence.read_set(store, log_id, query)

  def commit(store, plan) do
    current_revision = InMemoryPersistence.snapshot(store, plan.log_id).revision
    InMemoryPersistence.commit(store, %{plan | expected_revision: current_revision})
  end

  def frontier(store, log_id), do: InMemoryPersistence.frontier(store, log_id)

  def read_writer(store, log_id, writer_id, opts),
    do: InMemoryPersistence.read_writer(store, log_id, writer_id, opts)

  def tail_local(store, log_id, opts), do: InMemoryPersistence.tail_local(store, log_id, opts)
end

defmodule Commonplace.Log.Test.BrokenCreatingReadPersistence do
  @moduledoc "Deliberate contract mutation: every unknown-log read creates the log."
  @behaviour Commonplace.Log.Persistence

  alias Commonplace.Log.Test.InMemoryPersistence

  def create_log(store, log_id, metadata),
    do: InMemoryPersistence.create_log(store, log_id, metadata)

  def take_lease(store, log_id), do: InMemoryPersistence.take_lease(store, log_id)

  def read_set(store, log_id, query) do
    :ok = InMemoryPersistence.create_log(store, log_id, %{})
    InMemoryPersistence.read_set(store, log_id, query)
  end

  def commit(store, plan), do: InMemoryPersistence.commit(store, plan)

  def frontier(store, log_id) do
    :ok = InMemoryPersistence.create_log(store, log_id, %{})
    InMemoryPersistence.frontier(store, log_id)
  end

  def read_writer(store, log_id, writer_id, opts) do
    :ok = InMemoryPersistence.create_log(store, log_id, %{})
    InMemoryPersistence.read_writer(store, log_id, writer_id, opts)
  end

  def tail_local(store, log_id, opts) do
    :ok = InMemoryPersistence.create_log(store, log_id, %{})
    InMemoryPersistence.tail_local(store, log_id, opts)
  end
end
