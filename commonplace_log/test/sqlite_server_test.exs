defmodule Commonplace.LogStore.SQLite.ServerTest do
  use ExUnit.Case, async: false

  alias Commonplace.Log.Persistence.LocalSQLite
  alias Commonplace.LogStore.SQLite.Server

  @log_id "018f5e2a-8b3c-7d4e-9f10-123456789abc"
  @created_at ~U[2026-08-22 12:34:56Z]
  @append_count 100

  setup do
    data_dir =
      Path.join(
        System.tmp_dir!(),
        "commonplace-sqlite-server-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(data_dir) end)
    %{data_dir: data_dir}
  end

  test "starts, reports its writer id, and appends into the log database", %{data_dir: data_dir} do
    server = start_server(data_dir)
    writer_id = Server.writer_id(server)

    assert is_binary(writer_id)

    assert {:ok, %{writer_id: ^writer_id, writer_seq: 1}} =
             Server.append(server, %{"kind" => "note"}, @created_at)

    stop_server(server)
    assert writer_seqs(data_dir, writer_id) == [1]
  end

  test "a second same-node server is refused without disrupting the first", %{
    data_dir: data_dir
  } do
    first = start_server(data_dir)

    assert {:error, {:already_started, ^first}} =
             Server.start_link(data_dir: data_dir, log_id: @log_id)

    assert Process.alive?(first)
    assert {:ok, %{writer_seq: 1}} = Server.append(first, %{"still" => "serving"}, @created_at)
    stop_server(first)
  end

  test "a genuine second OS process observes the exclusive SQLite lock", %{data_dir: data_dir} do
    server = start_server(data_dir)
    lock_path = Path.join(data_dir, @log_id <> ".lock.sqlite3")

    expression = """
    alias Exqlite.Sqlite3
    {:ok, conn} = Sqlite3.open(#{inspect(lock_path)})
    result = Sqlite3.execute(conn, "BEGIN EXCLUSIVE")
    IO.puts("LOCK_RESULT=" <> inspect(result))
    Sqlite3.close(conn)
    """

    run_lock_probe = fn ->
      {output, 0} =
        System.cmd("mix", ["run", "--no-start", "-e", expression],
          cd: File.cwd!(),
          env: [{"MIX_ENV", "test"}],
          stderr_to_stdout: true
        )

      output
    end

    assert run_lock_probe.() =~ ~s(LOCK_RESULT={:error, "database is locked"})

    # Positive control through the SAME spawned-process path: once the holder is
    # gone the identical script must succeed. Without it, a probe that failed for
    # an unrelated reason would be indistinguishable from one the lock refused.
    stop_server(server)
    assert run_lock_probe.() =~ "LOCK_RESULT=:ok"
  end

  test "the lock is released when the server stops", %{data_dir: data_dir} do
    first = start_server(data_dir)
    stop_server(first)

    second = start_server(data_dir)
    assert Process.alive?(second)
    stop_server(second)
  end

  test "a fresh data directory creates and stores a writer id sidecar", %{data_dir: data_dir} do
    sidecar = writer_path(data_dir)
    refute File.exists?(sidecar)

    server = start_server(data_dir)
    writer_id = Server.writer_id(server)

    assert File.read!(sidecar) == writer_id
    stop_server(server)
  end

  test "a restart reuses the writer id from the sidecar", %{data_dir: data_dir} do
    first = start_server(data_dir)
    writer_id = Server.writer_id(first)
    stop_server(first)

    second = start_server(data_dir)
    assert Server.writer_id(second) == writer_id
    stop_server(second)
  end

  test "removing the sidecar before restart creates a different writer id", %{data_dir: data_dir} do
    first = start_server(data_dir)
    old_writer_id = Server.writer_id(first)
    stop_server(first)
    File.rm!(writer_path(data_dir))

    second = start_server(data_dir)
    new_writer_id = Server.writer_id(second)

    refute new_writer_id == old_writer_id
    assert File.read!(writer_path(data_dir)) == new_writer_id
    stop_server(second)
  end

  test "rekey persists a new identity and subsequent appends start its chain at one", %{
    data_dir: data_dir
  } do
    server = start_server(data_dir)
    old_writer_id = Server.writer_id(server)
    assert {:ok, %{writer_seq: 1}} = Server.append(server, %{"writer" => "old"}, @created_at)

    assert {:ok, new_writer_id} = Server.rekey(server)
    refute new_writer_id == old_writer_id
    assert Server.writer_id(server) == new_writer_id
    assert File.read!(writer_path(data_dir)) == new_writer_id

    assert {:ok, %{writer_id: ^new_writer_id, writer_seq: 1}} =
             Server.append(server, %{"writer" => "new"}, @created_at)

    stop_server(server)
    assert writer_seqs(data_dir, old_writer_id) == [1]
    assert writer_seqs(data_dir, new_writer_id) == [1]
  end

  test "100 concurrent callers produce one gapless writer chain", %{data_dir: data_dir} do
    server = start_server(data_dir)
    writer_id = Server.writer_id(server)

    results =
      1..@append_count
      |> Task.async_stream(
        fn n -> Server.append(server, %{"n" => n}, @created_at) end,
        max_concurrency: 20,
        ordered: false,
        timeout: 30_000
      )
      |> Enum.map(fn {:ok, {:ok, result}} -> result end)

    assert results |> Enum.map(& &1.writer_seq) |> Enum.sort() == Enum.to_list(1..@append_count)
    stop_server(server)
    assert writer_seqs(data_dir, writer_id) == Enum.to_list(1..@append_count)
  end

  defp start_server(data_dir) do
    assert {:ok, server} = Server.start_link(data_dir: data_dir, log_id: @log_id)
    server
  end

  defp stop_server(server), do: GenServer.stop(server)
  defp writer_path(data_dir), do: Path.join(data_dir, @log_id <> ".writer")

  defp writer_seqs(data_dir, writer_id) do
    assert {:ok, store} = LocalSQLite.open(data_dir, @log_id)

    assert {:ok, %{entries: entries}} =
             LocalSQLite.read_writer(store, @log_id, writer_id,
               after_seq: 0,
               through_seq: nil,
               limit: @append_count + 1
             )

    assert :ok = LocalSQLite.close(store)
    Enum.map(entries, & &1.writer_seq)
  end
end
