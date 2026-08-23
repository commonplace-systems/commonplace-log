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

  _unset ->
    :ok
end
