defmodule Commonplace.Log.RealmNodeTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias Commonplace.Log.{DocumentProfile, Entry, RealmNode, UUID}
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

    %{log_id: UUID.uuidv7(), data_dir: data_dir}
  end

  describe "log_id validation at the HTTP boundary" do
    test "a percent-encoded traversal log_id is rejected before persistence and writes no file outside data_dir",
         context do
      escaped_name = "#{Path.basename(context.data_dir)}-escaped"
      escape_target = Path.expand(Path.join(context.data_dir, "../#{escaped_name}.sqlite3"))
      on_exit(fn -> File.rm(escape_target) end)
      refute File.exists?(escape_target)

      assert %{
               "ok" => false,
               "error" => %{
                 "code" => "invalid_log_id",
                 "details" => %{"reason" => "uuid_malformed"}
               }
             } = request(:post, "/v1/logs/..%2F#{escaped_name}/create", %{}, 400)

      refute File.exists?(escape_target)

      # Rejected before any persistence adapter ran: open/2 would have created data_dir.
      refute File.exists?(context.data_dir)

      # Positive control: a canonical lowercase UUID still creates a log end-to-end.
      assert %{"ok" => true} = request(:post, "/v1/logs/#{context.log_id}/create", %{}, 201)
      assert File.exists?(Path.join(context.data_dir, context.log_id <> ".sqlite3"))
    end

    test "a deeper percent-encoded traversal on append is rejected with the error envelope",
         context do
      assert %{
               "ok" => false,
               "error" => %{
                 "code" => "invalid_log_id",
                 "details" => %{"reason" => "uuid_malformed"}
               }
             } =
               request(
                 :post,
                 "/v1/logs/..%2F..%2Fetc%2Fx/append",
                 %{"writer_id" => @writer_id, "body" => %{"value" => 1}},
                 400
               )

      refute File.exists?(context.data_dir)
    end

    test "a non-UUID log_id is rejected on every log route", context do
      for {method, path, body} <- [
            {:post, "/v1/logs/not-a-uuid/create", %{}},
            {:post, "/v1/logs/not-a-uuid/append", %{"writer_id" => @writer_id, "body" => %{}}},
            {:post, "/v1/logs/not-a-uuid/merge", %{"entries" => []}},
            {:get, "/v1/logs/not-a-uuid/frontier", nil}
          ] do
        assert %{
                 "ok" => false,
                 "error" => %{
                   "code" => "invalid_log_id",
                   "details" => %{"reason" => "uuid_malformed"}
                 }
               } = request(method, path, body, 400)
      end

      refute File.exists?(context.data_dir)
    end

    test "an uppercase UUID log_id is rejected as not lowercase", context do
      uppercase = String.upcase(context.log_id)

      assert %{
               "ok" => false,
               "error" => %{
                 "code" => "invalid_log_id",
                 "details" => %{"reason" => "uuid_not_lowercase"}
               }
             } = request(:post, "/v1/logs/#{uppercase}/create", %{}, 400)

      refute File.exists?(context.data_dir)
    end

    test "an empty log_id segment never reaches persistence", context do
      # An empty path segment collapses, so no :log_id route matches; the
      # catch-all 404 answers and no adapter runs.
      assert %{"ok" => false, "error" => %{"code" => "not_found"}} =
               request(:post, "/v1/logs//create", %{}, 404)

      refute File.exists?(context.data_dir)
    end

    test "next-style sha256-derived UUIDv7 log ids pass validation and round-trip the boundary",
         _context do
      # commonplace-next derives log ids (documents and chit-store alike) as
      # sha256(seed) -> first 16 bytes -> stamp UUIDv7 version/variant ->
      # lowercase 8-4-4-4-12. The seeds are arbitrary; the SHAPE is the contract.
      document_id = derived_log_id("document:workspace/notes.md")
      chit_id = derived_log_id("chit:2026-09-14/example")

      for id <- [document_id, chit_id] do
        assert Entry.uuid_problem(id) == nil

        # Guard the helper itself against drifting from the shape it claims:
        # version nibble "7" at position 14, variant nibble 10xx at position 19.
        assert String.at(id, 14) == "7"
        assert String.at(id, 19) in ~w(8 9 a b)
        assert id =~ ~r/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/
      end

      assert %{"ok" => true} = request(:post, "/v1/logs/#{document_id}/create", %{}, 201)

      assert %{"ok" => true, "entry" => %{"writer_seq" => 1}} =
               request(
                 :post,
                 "/v1/logs/#{document_id}/append",
                 %{"writer_id" => @writer_id, "body" => %{"derived" => true}},
                 200
               )

      assert %{
               "ok" => true,
               "frontier" => %{"writers" => [%{"writer_id" => @writer_id, "seq" => 1}]}
             } = request(:get, "/v1/logs/#{document_id}/frontier", nil, 200)
    end

    test "a traversal log_id on the document routes is rejected before the sidecar", _context do
      configure_sidecar()

      for path <- [
            "/v1/documents/..%2Fdoc-escape/create",
            "/v1/documents/..%2Fdoc-escape/open"
          ] do
        assert %{
                 "ok" => false,
                 "error" => %{
                   "code" => "invalid_log_id",
                   "details" => %{"reason" => "uuid_malformed"}
                 }
               } = request(:post, path, %{}, 400)
      end

      assert %{
               "ok" => false,
               "error" => %{
                 "code" => "invalid_log_id",
                 "details" => %{"reason" => "uuid_malformed"}
               }
             } =
               request(
                 :post,
                 "/v1/documents/..%2Fdoc-escape/append",
                 %{"body" => %{"n" => 1}},
                 400
               )
    end
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

  # Local reimplementation of commonplace-next's id derivation shape
  # (organization/identity.ex seed_document_id): sha256 of a seed string,
  # first 16 bytes, version nibble stamped to 7 and variant bits to 10xx,
  # formatted as a lowercase 8-4-4-4-12 UUID. Deliberately not imported
  # from next — this pins the wire shape, not their code.
  defp derived_log_id(seed) do
    <<head::binary-size(6), _::4, version_rest::12, _::2, variant_rest::62>> =
      binary_part(:crypto.hash(:sha256, seed), 0, 16)

    stamped = <<head::binary, 7::4, version_rest::12, 2::2, variant_rest::62>>

    <<p1::binary-size(8), p2::binary-size(4), p3::binary-size(4), p4::binary-size(4),
      p5::binary-size(12)>> = Base.encode16(stamped, case: :lower)

    Enum.join([p1, p2, p3, p4, p5], "-")
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
