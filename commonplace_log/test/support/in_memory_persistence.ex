defmodule Commonplace.Log.Test.InMemoryPersistence do
  @moduledoc "Map-backed persistence test adapter. State is owned by an Agent."

  @behaviour Commonplace.Log.Persistence

  alias Commonplace.Log.Entry
  alias Commonplace.Log.Persistence.{CommitPlan, ReadSet}

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{logs: %{}} end)
  end

  @impl true
  def create_log(store, log_id, metadata) do
    Agent.get_and_update(store, fn state ->
      case state.logs do
        %{^log_id => _log} ->
          {:ok, state}

        logs ->
          log = %{
            metadata: metadata,
            revision: 0,
            lease_epoch: 0,
            document_writer_id: nil,
            tips: %{},
            entries: %{},
            arrival_seq: 0
          }

          {:ok, put_in(state.logs, Map.put(logs, log_id, log))}
      end
    end)
  end

  @impl true
  def take_lease(store, log_id) do
    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.logs, log_id) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, log} ->
          epoch = log.lease_epoch + 1
          state = put_in(state.logs[log_id], %{log | lease_epoch: epoch})
          {{:ok, epoch}, state}
      end
    end)
  end

  def take_document_lease(store, log_id) do
    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.logs, log_id) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, log} ->
          epoch = log.lease_epoch + 1
          writer_id = log.document_writer_id || Commonplace.Log.UUID.uuidv7()
          log = %{log | lease_epoch: epoch, document_writer_id: writer_id}
          {{:ok, %{lease_epoch: epoch, writer_id: writer_id}}, put_in(state.logs[log_id], log)}
      end
    end)
  end

  @impl true
  def read_set(store, log_id, query) do
    with_log(store, log_id, fn log ->
      writers = Map.get(query, :writers, [])
      coordinates = Map.get(query, :coordinates, [])
      entry_ids = Map.get(query, :entry_ids, [])

      tips = Map.take(log.tips, writers)

      coordinate_rows =
        Map.new(coordinates, fn coordinate ->
          {coordinate, get_in(log.entries, [coordinate, :canonical_bytes])}
        end)
        |> Map.reject(fn {_coordinate, bytes} -> is_nil(bytes) end)

      id_rows =
        log.entries
        |> Map.values()
        |> Map.new(&{&1.entry_id, &1.canonical_bytes})
        |> Map.take(entry_ids)

      {:ok,
       %ReadSet{
         log_id: log_id,
         revision: log.revision,
         lease_epoch: log.lease_epoch,
         document_writer_id: log.document_writer_id,
         tips: tips,
         coordinates: coordinate_rows,
         entry_ids: id_rows
       }}
    end)
  end

  @impl true
  def commit(store, %CommitPlan{} = plan) do
    Agent.get_and_update(store, fn state ->
      case Map.fetch(state.logs, plan.log_id) do
        :error ->
          {{:error, :not_found}, state}

        {:ok, log} when log.revision != plan.expected_revision ->
          {{:error, :stale_revision}, state}

        {:ok, log} when log.lease_epoch != plan.expected_epoch ->
          {{:error, :obsolete_epoch}, state}

        {:ok, log} ->
          now = System.system_time(:millisecond)

          {entries, arrival_seq} =
            Enum.reduce(plan.insert_entries, {log.entries, log.arrival_seq}, fn row,
                                                                                {entries,
                                                                                 arrival_seq} ->
              arrival_seq = arrival_seq + 1

              stored =
                row
                |> Map.put(:received_at_ms, now)
                |> Map.put(:arrival_seq, arrival_seq)

              {Map.put(entries, {row.writer_id, row.writer_seq}, stored), arrival_seq}
            end)

          tips = Map.new(plan.put_tips, &{&1.writer_id, Map.take(&1, [:seq, :entry_id])})
          revision = log.revision + 1

          log = %{
            log
            | entries: entries,
              tips: Map.merge(log.tips, tips),
              revision: revision,
              arrival_seq: arrival_seq
          }

          state = put_in(state.logs[plan.log_id], log)
          {{:ok, revision}, state}
      end
    end)
  end

  @impl true
  def frontier(store, log_id) do
    with_log(store, log_id, fn log ->
      writers =
        log.tips
        |> Enum.map(fn {writer_id, tip} -> Map.put(tip, :writer_id, writer_id) end)
        |> Enum.sort_by(& &1.writer_id)

      {:ok, %{writers: writers}}
    end)
  end

  @impl true
  def read_writer(store, log_id, writer_id, opts) do
    with_log(store, log_id, fn log ->
      after_seq = Keyword.fetch!(opts, :after_seq)
      through_seq = Keyword.get(opts, :through_seq)
      limit = Keyword.fetch!(opts, :limit)

      rows =
        log.entries
        |> Enum.filter(fn {{candidate, seq}, _row} ->
          candidate == writer_id and seq > after_seq and
            (is_nil(through_seq) or seq <= through_seq)
        end)
        |> Enum.sort_by(fn {{_writer, seq}, _row} -> seq end)
        |> Enum.take(limit + 1)

      {page, more} = Enum.split(rows, limit)

      entries =
        Enum.map(page, fn {{_writer, writer_seq}, row} ->
          %{
            canonical_bytes: row.canonical_bytes,
            writer_seq: writer_seq,
            operation_id: Entry.operation_id(row.canonical_bytes)
          }
        end)

      {:ok,
       %{
         entries: entries,
         next_after_seq: if(more == [], do: nil, else: page |> List.last() |> elem(0) |> elem(1))
       }}
    end)
  end

  @impl true
  def tail_local(store, log_id, opts) do
    with_log(store, log_id, fn log ->
      after_arrival = Keyword.fetch!(opts, :after_arrival)
      limit = Keyword.fetch!(opts, :limit)

      rows =
        log.entries
        |> Map.values()
        |> Enum.filter(&(&1.arrival_seq > after_arrival))
        |> Enum.sort_by(& &1.arrival_seq)
        |> Enum.take(limit + 1)

      {page, more} = Enum.split(rows, limit)

      entries =
        Enum.map(page, fn row ->
          %{
            canonical_bytes: row.canonical_bytes,
            arrival_seq: row.arrival_seq,
            operation_id: Entry.operation_id(row.canonical_bytes)
          }
        end)

      {:ok,
       %{
         entries: entries,
         next_after_arrival:
           if(more == [], do: nil, else: page |> List.last() |> Map.fetch!(:arrival_seq))
       }}
    end)
  end

  def snapshot(store, log_id) do
    Agent.get(store, fn state -> Map.fetch!(state.logs, log_id) end)
  end

  defp with_log(store, log_id, fun) do
    Agent.get(store, fn state ->
      case Map.fetch(state.logs, log_id) do
        {:ok, log} -> fun.(log)
        :error -> {:error, :not_found}
      end
    end)
  end
end

defmodule Commonplace.Log.Test.StaleThenDelegatePersistence do
  @moduledoc "Injects stale revisions for the first N commits, then delegates."

  @behaviour Commonplace.Log.Persistence
  alias Commonplace.Log.Test.InMemoryPersistence

  def start_link(base, stale_count) do
    Agent.start_link(fn -> %{base: base, stale_count: stale_count, commit_calls: 0} end)
  end

  def create_log(store, log_id, metadata), do: delegate(store, :create_log, [log_id, metadata])
  def take_lease(store, log_id), do: delegate(store, :take_lease, [log_id])
  def read_set(store, log_id, query), do: delegate(store, :read_set, [log_id, query])
  def frontier(store, log_id), do: delegate(store, :frontier, [log_id])

  def read_writer(store, log_id, writer_id, opts),
    do: delegate(store, :read_writer, [log_id, writer_id, opts])

  def tail_local(store, log_id, opts), do: delegate(store, :tail_local, [log_id, opts])

  def commit(store, plan) do
    Agent.get_and_update(store, fn state ->
      state = Map.update!(state, :commit_calls, &(&1 + 1))

      if state.commit_calls <= state.stale_count do
        {{:error, :stale_revision}, state}
      else
        {InMemoryPersistence.commit(state.base, plan), state}
      end
    end)
  end

  def commit_calls(store), do: Agent.get(store, & &1.commit_calls)

  defp delegate(store, function, args) do
    base = Agent.get(store, & &1.base)
    apply(InMemoryPersistence, function, [base | args])
  end
end

defmodule Commonplace.Log.Test.CommitErrorPersistence do
  @moduledoc "Delegates reads but returns a configured non-stale commit error."

  alias Commonplace.Log.Test.InMemoryPersistence

  def create_log({base, _error}, log_id, metadata),
    do: InMemoryPersistence.create_log(base, log_id, metadata)

  def take_lease({base, _error}, log_id), do: InMemoryPersistence.take_lease(base, log_id)

  def read_set({base, _error}, log_id, query),
    do: InMemoryPersistence.read_set(base, log_id, query)

  def commit({_base, error}, _plan), do: {:error, error}
  def frontier({base, _error}, log_id), do: InMemoryPersistence.frontier(base, log_id)

  def read_writer({base, _error}, log_id, writer_id, opts),
    do: InMemoryPersistence.read_writer(base, log_id, writer_id, opts)

  def tail_local({base, _error}, log_id, opts),
    do: InMemoryPersistence.tail_local(base, log_id, opts)
end
