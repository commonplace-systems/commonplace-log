defmodule Commonplace.Log.Test.PersistenceContractStore do
  alias Commonplace.Log.Persistence.{CloudflareSidecar, LocalSQLite}
  alias Commonplace.Log.Test.{InMemoryPersistence, SidecarLoopback}
  alias Exqlite.Sqlite3

  def open(:local_sqlite, log_id) do
    data_dir =
      Path.join(System.tmp_dir!(), "persistence-contract-#{System.unique_integer([:positive])}")

    {:ok, store} = LocalSQLite.open(data_dir, log_id)

    %{
      module: LocalSQLite,
      store: store,
      logical_state: fn -> sqlite_state(store.conn) end,
      cleanup: fn ->
        LocalSQLite.close(store)
        File.rm_rf!(data_dir)
      end
    }
  end

  def open(:in_memory, _log_id), do: memory_store(InMemoryPersistence)

  def open(:cloudflare_sidecar, _log_id) do
    {:ok, base} = InMemoryPersistence.start_link()

    store =
      CloudflareSidecar.new("https://loopback.example",
        transport: SidecarLoopback,
        transport_options: {InMemoryPersistence, base}
      )

    %{
      module: CloudflareSidecar,
      store: store,
      logical_state: fn -> Agent.get(base, & &1) end,
      cleanup: fn -> :ok end
    }
  end

  def open(module, _log_id) when is_atom(module), do: memory_store(module)

  defp memory_store(module) do
    {:ok, base} = InMemoryPersistence.start_link()

    %{
      module: module,
      store: base,
      logical_state: fn -> Agent.get(base, & &1) end,
      cleanup: fn -> :ok end
    }
  end

  defp sqlite_state(conn) do
    tables =
      query(conn, "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name")
      |> Enum.map(&hd/1)

    if "log_meta" in tables do
      %{
        tables: tables,
        logs: query(conn, "SELECT log_id FROM log_meta ORDER BY log_id"),
        entries: query(conn, "SELECT entry_id FROM entries ORDER BY entry_id"),
        meta: query(conn, "SELECT revision, lease_epoch FROM persistence_meta")
      }
    else
      %{tables: tables}
    end
  end

  defp query(conn, sql) do
    {:ok, stmt} = Sqlite3.prepare(conn, sql)
    rows = fetch_all(conn, stmt, [])
    :ok = Sqlite3.release(conn, stmt)
    rows
  end

  defp fetch_all(conn, stmt, rows) do
    case Sqlite3.step(conn, stmt) do
      {:row, row} -> fetch_all(conn, stmt, [row | rows])
      :done -> Enum.reverse(rows)
    end
  end
end

defmodule Commonplace.Log.Test.PersistenceContract do
  defmacro __using__(options) do
    adapter = Keyword.fetch!(options, :adapter)

    quote bind_quoted: [adapter: adapter] do
      alias Commonplace.Log.Persistence.{CommitPlan, ReadSet}
      alias Commonplace.Log.Test.PersistenceContractStore

      @contract_adapter adapter
      @log_id "018f1000-0000-7000-8000-000000000001"

      setup do
        contract = PersistenceContractStore.open(@contract_adapter, @log_id)
        on_exit(contract.cleanup)
        contract
      end

      test "create_log is idempotent and starts at revision and epoch zero", contract do
        assert :ok = create_log(contract)
        assert :ok = create_log(contract)
        assert {:ok, %ReadSet{revision: 0, lease_epoch: 0}} = read_set(contract)
      end

      test "read_set is a coherent selective snapshot with revision and lease epoch", contract do
        assert :ok = create_log(contract)
        assert {:ok, 1} = contract.module.take_lease(contract.store, @log_id)
        assert {:ok, 1} = contract.module.commit(contract.store, plan(0, 1, rows()))

        query = %{
          writers: ["writer-a", "missing"],
          coordinates: [{"writer-b", 1}, {"writer-b", 99}],
          entry_ids: ["entry-a1", "missing"]
        }

        assert {:ok,
                %ReadSet{
                  log_id: @log_id,
                  revision: 1,
                  lease_epoch: 1,
                  tips: %{"writer-a" => %{seq: 2, entry_id: "entry-a2"}},
                  coordinates: %{{"writer-b", 1} => "b1"},
                  entry_ids: %{"entry-a1" => "a1"}
                }} = contract.module.read_set(contract.store, @log_id, query)
      end

      test "commit uses revision CAS and a stale revision writes nothing", contract do
        assert :ok = create_log(contract)
        assert {:ok, 1} = contract.module.commit(contract.store, plan(0, 0, [row("a", 1)]))
        before = contract.logical_state.()

        assert {:error, :stale_revision} =
                 contract.module.commit(contract.store, plan(0, 0, [row("stale", 2)]))

        assert contract.logical_state.() == before
      end

      test "leases are monotonic and epoch and revision failures stay distinct and write nothing",
           contract do
        assert :ok = create_log(contract)
        assert {:ok, 1} = contract.module.take_lease(contract.store, @log_id)
        assert {:ok, 2} = contract.module.take_lease(contract.store, @log_id)
        before = contract.logical_state.()

        assert {:error, :obsolete_epoch} =
                 contract.module.commit(contract.store, plan(0, 1, [row("obsolete", 1)]))

        assert contract.logical_state.() == before

        assert {:error, :stale_revision} =
                 contract.module.commit(contract.store, plan(99, 2, [row("stale", 1)]))

        assert contract.logical_state.() == before
        assert {:ok, 1} = contract.module.commit(contract.store, plan(0, 2, [row("current", 1)]))
      end

      test "frontier has the pinned shape and writer ordering", contract do
        assert :ok = create_log(contract)
        assert {:ok, 1} = contract.module.commit(contract.store, plan(0, 0, rows()))

        assert {:ok,
                %{
                  writers: [
                    %{writer_id: "writer-a", seq: 2, entry_id: "entry-a2"},
                    %{writer_id: "writer-b", seq: 1, entry_id: "entry-b1"}
                  ]
                }} = contract.module.frontier(contract.store, @log_id)
      end

      test "read_writer pins continuation cursor presence and values", contract do
        assert :ok = create_log(contract)
        writer_rows = Enum.map(1..3, &row("writer", &1))
        assert {:ok, 1} = contract.module.commit(contract.store, plan(0, 0, writer_rows))

        assert {:ok, %{entries: first, next_after_seq: 2}} =
                 contract.module.read_writer(contract.store, @log_id, "writer",
                   after_seq: 0,
                   through_seq: 3,
                   limit: 2
                 )

        assert Enum.map(first, & &1.writer_seq) == [1, 2]

        assert {:ok, %{entries: last, next_after_seq: nil}} =
                 contract.module.read_writer(contract.store, @log_id, "writer",
                   after_seq: 2,
                   through_seq: 3,
                   limit: 2
                 )

        assert Enum.map(last, & &1.writer_seq) == [3]
      end

      test "tail_local pins arrival continuation cursor presence and values", contract do
        assert :ok = create_log(contract)
        assert {:ok, 1} = contract.module.commit(contract.store, plan(0, 0, rows()))

        assert {:ok, %{entries: first, next_after_arrival: 2}} =
                 contract.module.tail_local(contract.store, @log_id, after_arrival: 0, limit: 2)

        assert Enum.map(first, & &1.canonical_bytes) == ["b1", "a1"]

        assert {:ok, %{entries: last, next_after_arrival: nil}} =
                 contract.module.tail_local(contract.store, @log_id,
                   after_arrival: 2,
                   limit: 2
                 )

        assert Enum.map(last, & &1.canonical_bytes) == ["a2"]
      end

      test "all reads of an unknown log return not_found and create no logical state", contract do
        before = contract.logical_state.()
        query = %{writers: [], coordinates: [], entry_ids: []}

        assert {:error, :not_found} = contract.module.read_set(contract.store, @log_id, query)
        assert {:error, :not_found} = contract.module.frontier(contract.store, @log_id)

        assert {:error, :not_found} =
                 contract.module.read_writer(contract.store, @log_id, "writer",
                   after_seq: 0,
                   limit: 1
                 )

        assert {:error, :not_found} =
                 contract.module.tail_local(contract.store, @log_id,
                   after_arrival: 0,
                   limit: 1
                 )

        assert contract.logical_state.() == before
      end

      defp create_log(contract), do: contract.module.create_log(contract.store, @log_id, %{})

      defp read_set(contract) do
        contract.module.read_set(contract.store, @log_id, %{
          writers: [],
          coordinates: [],
          entry_ids: []
        })
      end

      defp rows do
        [row("writer-b", 1), row("writer-a", 1), row("writer-a", 2)]
      end

      defp row(writer_id, seq) do
        suffix = String.replace(writer_id, "writer-", "") <> Integer.to_string(seq)

        %{
          log_id: @log_id,
          entry_id: "entry-#{suffix}",
          writer_id: writer_id,
          writer_seq: seq,
          prev_entry_id:
            if(seq == 1,
              do: nil,
              else: "entry-#{String.replace(writer_id, "writer-", "")}#{seq - 1}"
            ),
          created_at: "2026-08-23T12:34:56Z",
          canonical_bytes: suffix
        }
      end

      defp plan(revision, epoch, rows) do
        tips =
          rows
          |> Enum.group_by(& &1.writer_id)
          |> Enum.map(fn {writer_id, writer_rows} ->
            latest = Enum.max_by(writer_rows, & &1.writer_seq)
            %{writer_id: writer_id, seq: latest.writer_seq, entry_id: latest.entry_id}
          end)

        %CommitPlan{
          log_id: @log_id,
          expected_revision: revision,
          expected_epoch: epoch,
          insert_entries: rows,
          put_tips: tips
        }
      end
    end
  end
end
