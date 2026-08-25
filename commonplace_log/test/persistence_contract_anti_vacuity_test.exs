Code.require_file("support/persistence_contract.ex", __DIR__)
Code.require_file("support/broken_persistence.ex", __DIR__)

case System.get_env("PERSISTENCE_CONTRACT_MUTATION") do
  "epoch" ->
    defmodule Commonplace.Log.PersistenceContract.BrokenEpochTest do
      use ExUnit.Case, async: true

      use Commonplace.Log.Test.PersistenceContract,
        adapter: Commonplace.Log.Test.BrokenEpochPersistence
    end

  "revision" ->
    defmodule Commonplace.Log.PersistenceContract.BrokenRevisionTest do
      use ExUnit.Case, async: true

      use Commonplace.Log.Test.PersistenceContract,
        adapter: Commonplace.Log.Test.BrokenRevisionPersistence
    end

  "creating_read" ->
    defmodule Commonplace.Log.PersistenceContract.BrokenCreatingReadTest do
      use ExUnit.Case, async: true

      use Commonplace.Log.Test.PersistenceContract,
        adapter: Commonplace.Log.Test.BrokenCreatingReadPersistence
    end

  "sidecar_lane_epoch" ->
    defmodule Commonplace.Log.PersistenceContract.BrokenSidecarLaneEpochTest do
      use ExUnit.Case, async: true

      alias Commonplace.Log.{DocumentProfile, Engine, UUID}
      alias Commonplace.Log.DocumentProfile.Lane.Sidecar
      alias Commonplace.Log.Persistence.CloudflareSidecar
      alias Commonplace.Log.Test.{InMemoryPersistence, SidecarLoopback}

      defmodule BrokenSidecarLane do
        @behaviour Commonplace.Log.DocumentProfile.Lane

        defdelegate create_log(log_id, store), to: Sidecar
        defdelegate open_log(log_id, store), to: Sidecar
        defdelegate activate(log_id, store), to: Sidecar
        defdelegate writer_id(handle), to: Sidecar
        defdelegate frontier(handle), to: Sidecar
        defdelegate read_writer(handle, opts), to: Sidecar

        def append_with_epoch(handle, body, created_at, _expected_epoch) do
          Engine.append(
            CloudflareSidecar,
            handle.store,
            handle.log_id,
            handle.writer_id,
            body,
            created_at
          )
        end

        def merge_with_epoch(handle, entries, _expected_epoch) do
          Engine.merge(CloudflareSidecar, handle.store, handle.log_id, entries)
        end
      end

      test "obsolete sidecar lane authority writes nothing" do
        {:ok, base} = InMemoryPersistence.start_link()

        store =
          CloudflareSidecar.new("https://loopback.example",
            transport: SidecarLoopback,
            transport_options: {InMemoryPersistence, base}
          )

        log_id = UUID.uuidv7()
        lane = [lane: {BrokenSidecarLane, store}]
        assert {:ok, first} = DocumentProfile.create_log(log_id, lane)
        assert {:ok, _second} = DocumentProfile.open_log(log_id, lane)

        assert {:error, {:writer_lease_fenced, %{}}} =
                 DocumentProfile.append(first, %{"must_not_write" => true}, [])

        assert {:ok, %{writers: []}} = CloudflareSidecar.frontier(store, log_id)
      end
    end

  _unset ->
    :ok
end
