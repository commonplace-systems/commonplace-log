Code.require_file("support/persistence_contract.ex", __DIR__)

defmodule Commonplace.Log.PersistenceContract.LocalSQLiteTest do
  use ExUnit.Case, async: true
  use Commonplace.Log.Test.PersistenceContract, adapter: :local_sqlite
end

defmodule Commonplace.Log.PersistenceContract.InMemoryTest do
  use ExUnit.Case, async: true
  use Commonplace.Log.Test.PersistenceContract, adapter: :in_memory
end

defmodule Commonplace.Log.PersistenceContract.CloudflareSidecarTest do
  use ExUnit.Case, async: true
  use Commonplace.Log.Test.PersistenceContract, adapter: :cloudflare_sidecar
end
