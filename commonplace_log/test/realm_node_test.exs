defmodule Commonplace.Log.RealmNodeTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Commonplace.Log.{DocumentProfile, RealmNode, UUID}
  alias Commonplace.Log.DocumentProfile.Lane.Sidecar, as: SidecarLane
  alias Commonplace.Log.Persistence.CloudflareSidecar
  alias Commonplace.Log.RealmNode.DocumentHandles
  alias Commonplace.Log.Test.{InMemoryPersistence, SidecarLoopback}

  @writer_id "018f5e2a-8b3c-7d4e-9f10-123456789abd"

  setup do
    DocumentHandles.clear()

    data_dir =
      Path.join(System.tmp_dir!(), "realm-node-#{System.unique_integer([:positive])}")

    previous = Application.get_env(:commonplace_log, RealmNode)

    Application.put_env(:commonplace_log, RealmNode,
      persistence: {Commonplace.Log.Persistence.LocalSQLite, data_dir: data_dir}
    )

    on_exit(fn ->
      if previous do
        Application.put_env(:commonplace_log, RealmNode, previous)
      else
        Application.delete_env(:commonplace_log, RealmNode)
      end

      File.rm_rf!(data_dir)
    end)

    %{log_id: UUID.uuidv7()}
  end

  test "create, append, and frontier round trip; one writer advances from seq 1 to 2", context do
    assert %{"ok" => true} =
             request(:post, "/v1/logs/#{context.log_id}/create", %{}, 201)

    assert %{
             "ok" => false,
             "error" => %{"code" => "already_exists", "details" => %{}}
           } = request(:post, "/v1/logs/#{context.log_id}/create", %{}, 409)

    first =
      request(
        :post,
        "/v1/logs/#{context.log_id}/append",
        %{"writer_id" => @writer_id, "body" => %{"value" => 1}},
        200
      )

    assert %{
             "ok" => true,
             "entry" => %{
               "entry_id" => first_entry_id,
               "writer_id" => @writer_id,
               "writer_seq" => 1
             },
             "revision" => 1
           } = first

    second =
      request(
        :post,
        "/v1/logs/#{context.log_id}/append",
        %{
          "writer_id" => @writer_id,
          "body" => %{"value" => 2},
          "created_at" => "2026-08-24T12:00:00Z"
        },
        200
      )

    assert %{
             "ok" => true,
             "entry" => %{
               "entry_id" => second_entry_id,
               "writer_id" => @writer_id,
               "writer_seq" => 2
             },
             "revision" => 2
           } = second

    assert first_entry_id != second_entry_id

    assert %{
             "ok" => true,
             "frontier" => %{
               "writers" => [
                 %{"writer_id" => @writer_id, "seq" => 2, "entry_id" => ^second_entry_id}
               ]
             }
           } = request(:get, "/v1/logs/#{context.log_id}/frontier", nil, 200)
  end

  test "a coordinate fork is reported, refused, and leaves the frontier unchanged", context do
    request(:post, "/v1/logs/#{context.log_id}/create", %{}, 201)

    request(
      :post,
      "/v1/logs/#{context.log_id}/append",
      %{"writer_id" => @writer_id, "body" => %{"accepted" => true}},
      200
    )

    frontier_before = request(:get, "/v1/logs/#{context.log_id}/frontier", nil, 200)

    fork = %{
      "version" => 1,
      "log_id" => context.log_id,
      "entry_id" => UUID.uuidv7(),
      "writer_id" => @writer_id,
      "writer_seq" => 1,
      "prev_entry_id" => nil,
      "created_at" => "2026-08-24T12:01:00Z",
      "body" => %{"accepted" => false}
    }

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "writer_fork",
               "details" => %{"writer_id" => @writer_id, "seq" => 1}
             }
           } =
             request(
               :post,
               "/v1/logs/#{context.log_id}/merge",
               %{"entries" => [fork]},
               409
             )

    assert request(:get, "/v1/logs/#{context.log_id}/frontier", nil, 200) == frontier_before
  end

  test "an unknown log is a 404", _context do
    missing = UUID.uuidv7()

    assert %{
             "ok" => false,
             "error" => %{"code" => "log_not_found", "details" => %{}}
           } = request(:get, "/v1/logs/#{missing}/frontier", nil, 404)
  end

  test "malformed JSON is a 400", context do
    conn = conn(:post, "/v1/logs/#{context.log_id}/append", "{")
    conn = RealmNode.call(put_req_header(conn, "content-type", "application/json"), [])

    assert conn.status == 400

    assert %{
             "ok" => false,
             "error" => %{
               "code" => "invalid_entry",
               "details" => %{"reason" => "malformed-json"}
             }
           } = Jason.decode!(conn.resp_body)
  end

  test "incarnation identity is stable within one application boot", _context do
    first = request(:get, "/v1/incarnation", nil, 200)
    second = request(:get, "/v1/incarnation", nil, 200)

    assert %{"ok" => true, "incarnation_id" => incarnation_id, "booted_at" => booted_at} = first
    assert second == first
    assert is_binary(incarnation_id)
    assert {:ok, _datetime, _offset} = DateTime.from_iso8601(booted_at)
  end

  test "the application does not start Bandit when the HTTP port environment variable is unset" do
    assert System.get_env("COMMONPLACE_REALM_HTTP_PORT") == nil
    assert Process.whereis(Commonplace.Log.RealmNode.HTTP) == nil
  end

  test "document create, append, and open use the durable sidecar writer lane", context do
    store = configure_sidecar()

    assert %{"ok" => true, "writer_id" => writer_id, "lease_epoch" => 1} =
             request(:post, "/v1/documents/#{context.log_id}/create", %{}, 201)

    assert %{"ok" => true, "result" => %{"inserted" => 1, "present" => 0}} =
             request(
               :post,
               "/v1/documents/#{context.log_id}/append",
               %{"body" => %{"n" => 1}, "created_at" => "2026-08-25T12:00:00Z"},
               200
             )

    assert %{"ok" => true, "writer_id" => ^writer_id, "lease_epoch" => 2} =
             request(:post, "/v1/documents/#{context.log_id}/open", %{}, 200)

    assert %{"ok" => true} =
             request(
               :post,
               "/v1/documents/#{context.log_id}/append",
               %{"body" => %{"n" => 2}},
               200
             )

    assert {:ok, %{writers: [%{writer_id: ^writer_id, seq: 2}]}} =
             CloudflareSidecar.frontier(store, context.log_id)
  end

  test "a fenced cached document handle is dropped and maps to 409 without a write", context do
    store = configure_sidecar()
    request(:post, "/v1/documents/#{context.log_id}/create", %{}, 201)

    assert {:ok, _new_incarnation} =
             DocumentProfile.open_log(context.log_id, lane: {SidecarLane, store})

    assert %{
             "ok" => false,
             "error" => %{"code" => "writer_lease_fenced", "details" => %{}}
           } =
             request(
               :post,
               "/v1/documents/#{context.log_id}/append",
               %{"body" => %{"must_not_write" => true}},
               409
             )

    assert :error = DocumentHandles.fetch(context.log_id)
    assert {:ok, %{writers: []}} = CloudflareSidecar.frontier(store, context.log_id)
  end

  test "the dev lever delays between prepare and commit and exposes an obsolete incarnation",
       context do
    store = configure_sidecar()
    request(:post, "/v1/documents/#{context.log_id}/create", %{}, 201)
    previous = System.get_env("COMMONPLACE_REALM_TEST_LEVERS")
    System.put_env("COMMONPLACE_REALM_TEST_LEVERS", "1")
    on_exit(fn -> restore_env("COMMONPLACE_REALM_TEST_LEVERS", previous) end)

    append =
      Task.async(fn ->
        request_with_headers(
          :post,
          "/v1/documents/#{context.log_id}/append",
          %{"body" => %{"delayed" => true}},
          [{"x-commonplace-test-commit-delay-ms", "150"}],
          409
        )
      end)

    Process.sleep(50)

    assert {:ok, _new_incarnation} =
             DocumentProfile.open_log(context.log_id, lane: {SidecarLane, store})

    assert %{"error" => %{"code" => "writer_lease_fenced"}} = Task.await(append, 1_000)
    assert {:ok, %{writers: []}} = CloudflareSidecar.frontier(store, context.log_id)
  end

  test "the delay header is ignored unless the dev lever is exactly one", context do
    _store = configure_sidecar()
    request(:post, "/v1/documents/#{context.log_id}/create", %{}, 201)
    previous = System.get_env("COMMONPLACE_REALM_TEST_LEVERS")
    System.put_env("COMMONPLACE_REALM_TEST_LEVERS", "true")
    on_exit(fn -> restore_env("COMMONPLACE_REALM_TEST_LEVERS", previous) end)

    started = System.monotonic_time(:millisecond)

    assert %{"ok" => true} =
             request_with_headers(
               :post,
               "/v1/documents/#{context.log_id}/append",
               %{"body" => %{"not_delayed" => true}},
               [{"x-commonplace-test-commit-delay-ms", "1000"}],
               200
             )

    assert System.monotonic_time(:millisecond) - started < 700
  end

  defp configure_sidecar do
    {:ok, base} = InMemoryPersistence.start_link()

    store =
      CloudflareSidecar.new("https://loopback.example",
        transport: SidecarLoopback,
        transport_options: {InMemoryPersistence, base}
      )

    Application.put_env(:commonplace_log, RealmNode, persistence: {CloudflareSidecar, store})
    store
  end

  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)

  defp request(method, path, nil, expected_status) do
    conn = RealmNode.call(conn(method, path), [])
    assert conn.status == expected_status
    Jason.decode!(conn.resp_body)
  end

  defp request(method, path, body, expected_status) do
    conn = conn(method, path, Jason.encode!(body))
    conn = RealmNode.call(put_req_header(conn, "content-type", "application/json"), [])
    assert conn.status == expected_status
    Jason.decode!(conn.resp_body)
  end

  defp request_with_headers(method, path, body, headers, expected_status) do
    conn = conn(method, path, Jason.encode!(body))

    conn =
      Enum.reduce([{"content-type", "application/json"} | headers], conn, fn {name, value}, acc ->
        put_req_header(acc, name, value)
      end)

    conn = RealmNode.call(conn, [])
    assert conn.status == expected_status
    Jason.decode!(conn.resp_body)
  end
end
