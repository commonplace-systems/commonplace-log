defmodule Commonplace.Log.RealmNodeTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Commonplace.Log.{RealmNode, UUID}

  @writer_id "018f5e2a-8b3c-7d4e-9f10-123456789abd"

  setup do
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
end
