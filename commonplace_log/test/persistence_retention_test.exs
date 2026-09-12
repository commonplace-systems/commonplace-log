defmodule Commonplace.Log.Persistence.RetentionTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.{Engine, UUID}
  alias Commonplace.Log.Persistence.{LocalSQLite, Retention}

  test "SQLite closure survives close and reopen through the owner capability" do
    data_dir = Path.join(System.tmp_dir!(), "retention-#{System.unique_integer([:positive])}")
    log_id = UUID.uuidv7()
    File.mkdir_p!(data_dir)

    on_exit(fn -> File.rm_rf!(data_dir) end)

    assert {:ok, store} = LocalSQLite.open(data_dir, log_id)
    assert :ok = LocalSQLite.create_log(store, log_id, %{format_version: 1})
    writer_id = UUID.uuidv7()
    assert {:ok, _} = Engine.append(LocalSQLite, store, log_id, writer_id, %{"node" => "root"}, "2026-01-01T00:00:00Z")

    verifier = fn reopened ->
      with {:ok, %{entries: entries}} <- LocalSQLite.tail_local(reopened, log_id, after_arrival: 0, limit: 10),
           true <- length(entries) == 1 do
        {:ok, Enum.map(entries, & &1.operation_id)}
      else
        false -> {:error, :closure_incomplete}
        error -> error
      end
    end

    assert {:ok, lease} = Retention.retain(store, verifier)
    assert lease.capability.mode == :append_only
    assert lease.capability.durable_across_restart?
    assert lease.capability.deletion == :unsupported
    assert :ok = LocalSQLite.close(store)

    assert {:ok, reopened} = LocalSQLite.open(data_dir, log_id)
    assert {:ok, renewed} = Retention.renew(lease, reopened, verifier)
    assert renewed.closure == lease.closure
    assert {:ok, released} = Retention.release(renewed)
    assert {:error, :lease_released} = Retention.renew(released, reopened, verifier)
    assert :ok = LocalSQLite.close(reopened)
  end

  test "renew reports a missing child from the real reopened SQLite resolver" do
    data_dir = Path.join(System.tmp_dir!(), "retention-#{System.unique_integer([:positive])}")
    log_id = UUID.uuidv7()
    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)

    assert {:ok, store} = LocalSQLite.open(data_dir, log_id)
    assert :ok = LocalSQLite.create_log(store, log_id, %{format_version: 1})
    writer_id = UUID.uuidv7()
    assert {:ok, _} = Engine.append(LocalSQLite, store, log_id, writer_id, %{"node" => "root"}, "2026-01-01T00:00:00Z")
    verifier = fn candidate ->
      case LocalSQLite.tail_local(candidate, log_id, after_arrival: 0, limit: 10) do
        {:ok, %{entries: [_root, _child] = entries}} ->
          {:ok, Enum.map(entries, & &1.operation_id)}

        {:ok, _} ->
          {:error, :closure_incomplete}

        error ->
          error
      end
    end

    assert {:error, :closure_incomplete} = Retention.retain(store, verifier)
    assert :ok = LocalSQLite.close(store)
  end

  test "retention does not infer support for an unknown persistence adapter" do
    assert {:error, :unsupported_retention_backend} = Retention.capability(%{})
  end
end
