defmodule Commonplace.Log.Persistence.CloudflareSidecarTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.Persistence.{CloudflareSidecar, CommitPlan, ReadSet}

  defmodule TransportDouble do
    @behaviour Commonplace.Log.Persistence.CloudflareSidecar.Transport

    def start_link(responses), do: Agent.start_link(fn -> {responses, []} end)

    @impl true
    def request(method, url, headers, body, pid) do
      request = %{method: method, url: url, headers: headers, body: Jason.decode!(body)}

      Agent.get_and_update(pid, fn
        {[response | rest], requests} -> {response, {rest, [request | requests]}}
        {[], _requests} -> raise "unexpected transport request"
      end)
    end

    def requests(pid) do
      Agent.get(pid, fn {_responses, requests} -> Enum.reverse(requests) end)
    end
  end

  defmodule LostAckTransport do
    @behaviour Commonplace.Log.Persistence.CloudflareSidecar.Transport

    @impl true
    def request(_method, _url, _headers, _body, test_pid) do
      send(test_pid, :commit_applied)
      {:error, :ack_lost}
    end
  end

  @high_bytes <<0, 127, 128, 254, 255>>
  @encoded_high_bytes Base.encode64(@high_bytes)

  test "every callback emits the pinned request and parses the pinned response" do
    responses = [
      response(201, %{"ok" => true}),
      response(200, %{"ok" => true, "lease_epoch" => 7}),
      response(200, %{
        "ok" => true,
        "read_set" => %{
          "log_id" => "log-a",
          "format_version" => 1,
          "revision" => 3,
          "lease_epoch" => 7,
          "tips" => [%{"writer_id" => "alice", "last_seq" => 2, "last_entry_id" => "e2"}],
          "coordinates" => [
            %{"writer_id" => "alice", "writer_seq" => 2, "canonical_bytes" => @encoded_high_bytes}
          ],
          "entry_ids" => [%{"entry_id" => "e2", "canonical_bytes" => @encoded_high_bytes}]
        }
      }),
      response(200, %{"ok" => true, "revision" => 4}),
      response(200, %{
        "ok" => true,
        "frontier" => %{
          "writers" => [%{"writer_id" => "alice", "seq" => 2, "entry_id" => "e2"}]
        }
      }),
      response(200, %{
        "ok" => true,
        "page" => %{
          "entries" => [%{"canonical_bytes" => @encoded_high_bytes, "writer_seq" => 2}],
          "next_after_seq" => nil
        }
      }),
      response(200, %{
        "ok" => true,
        "page" => %{
          "entries" => [%{"canonical_bytes" => @encoded_high_bytes, "arrival_seq" => 9}],
          "next_after_arrival" => 9
        }
      })
    ]

    {:ok, transport} = TransportDouble.start_link(responses)

    store =
      CloudflareSidecar.new("https://sidecar.example/",
        transport: TransportDouble,
        transport_options: transport
      )

    assert :ok =
             CloudflareSidecar.create_log(store, "log-a", %{
               format_version: 1,
               created_at: "2026-08-23T00:00:00Z"
             })

    assert {:ok, 7} = CloudflareSidecar.take_lease(store, "log-a")

    assert {:ok,
            %ReadSet{
              log_id: "log-a",
              revision: 3,
              lease_epoch: 7,
              tips: %{"alice" => %{seq: 2, entry_id: "e2"}},
              coordinates: %{{"alice", 2} => @high_bytes},
              entry_ids: %{"e2" => @high_bytes}
            }} =
             CloudflareSidecar.read_set(store, "log-a", %{
               writers: ["alice"],
               coordinates: [{"alice", 2}],
               entry_ids: ["e2"]
             })

    plan = %CommitPlan{
      log_id: "log-a",
      expected_revision: 3,
      expected_epoch: 7,
      insert_entries: [
        %{
          log_id: "log-a",
          entry_id: "e3",
          writer_id: "alice",
          writer_seq: 3,
          prev_entry_id: "e2",
          created_at: "2026-08-23T00:01:00Z",
          canonical_bytes: @high_bytes
        }
      ],
      put_tips: [%{writer_id: "alice", seq: 3, entry_id: "e3"}]
    }

    assert {:ok, 4} = CloudflareSidecar.commit(store, plan)

    assert {:ok, %{writers: [%{writer_id: "alice", seq: 2, entry_id: "e2"}]}} =
             CloudflareSidecar.frontier(store, "log-a")

    assert {:ok,
            %{entries: [%{canonical_bytes: @high_bytes, writer_seq: 2}], next_after_seq: nil}} =
             CloudflareSidecar.read_writer(store, "log-a", "alice",
               after_seq: 1,
               through_seq: 2,
               limit: 10
             )

    assert {:ok,
            %{
              entries: [%{canonical_bytes: @high_bytes, arrival_seq: 9}],
              next_after_arrival: 9
            }} = CloudflareSidecar.tail_local(store, "log-a", after_arrival: 4, limit: 10)

    assert [create, lease, read_set, commit, frontier, read_writer, tail_local] =
             TransportDouble.requests(transport)

    assert_request(create, "/create-log", %{
      "log_id" => "log-a",
      "format_version" => 1,
      "created_at" => "2026-08-23T00:00:00Z"
    })

    assert_request(lease, "/take-lease", %{"log_id" => "log-a"})

    assert_request(read_set, "/read-set", %{
      "log_id" => "log-a",
      "writers" => ["alice"],
      "coordinates" => [%{"writer_id" => "alice", "writer_seq" => 2}],
      "entry_ids" => ["e2"]
    })

    assert_request(commit, "/commit", %{
      "log_id" => "log-a",
      "expected_revision" => 3,
      "expected_epoch" => 7,
      "insert_entries" => [
        %{
          "log_id" => "log-a",
          "entry_id" => "e3",
          "writer_id" => "alice",
          "writer_seq" => 3,
          "prev_entry_id" => "e2",
          "created_at" => "2026-08-23T00:01:00Z",
          "canonical_bytes" => @encoded_high_bytes
        }
      ],
      "put_tips" => [%{"writer_id" => "alice", "last_seq" => 3, "last_entry_id" => "e3"}]
    })

    refute Map.has_key?(hd(commit.body["insert_entries"]), "received_at_ms")
    assert_request(frontier, "/frontier", %{"log_id" => "log-a"})

    assert_request(read_writer, "/read-writer", %{
      "log_id" => "log-a",
      "writer_id" => "alice",
      "after_seq" => 1,
      "through_seq" => 2,
      "limit" => 10
    })

    assert_request(tail_local, "/tail-local", %{
      "log_id" => "log-a",
      "after_arrival" => 4,
      "limit" => 10
    })
  end

  test "read_writer omits an absent through_seq instead of sending null" do
    {:ok, transport} =
      TransportDouble.start_link([
        response(200, %{
          "ok" => true,
          "page" => %{"entries" => [], "next_after_seq" => nil}
        })
      ])

    store = store(transport)

    assert {:ok, %{entries: [], next_after_seq: nil}} =
             CloudflareSidecar.read_writer(store, "log-a", "alice", after_seq: 0, limit: 1)

    assert [request] = TransportDouble.requests(transport)
    refute Map.has_key?(request.body, "through_seq")
  end

  test "stale revision and obsolete epoch remain distinct local-adapter terms" do
    for {code, expected} <- [
          {"stale_revision", :stale_revision},
          {"obsolete_epoch", :obsolete_epoch}
        ] do
      {:ok, transport} = TransportDouble.start_link([error_response(409, code)])
      assert {:error, ^expected} = CloudflareSidecar.commit(store(transport), empty_plan())
    end
  end

  test "unknown-log read returns not_found and never sends a create request" do
    {:ok, transport} = TransportDouble.start_link([error_response(404, "not_found")])

    assert {:error, :not_found} =
             CloudflareSidecar.read_set(store(transport), "missing", %{
               writers: [],
               coordinates: [],
               entry_ids: []
             })

    assert [%{url: "https://sidecar.example/read-set"}] = TransportDouble.requests(transport)
  end

  test "a read set for another log is a log_mismatch storage fact" do
    {:ok, transport} =
      TransportDouble.start_link([
        response(200, %{
          "ok" => true,
          "read_set" => %{
            "log_id" => "other-log",
            "format_version" => 1,
            "revision" => 0,
            "lease_epoch" => 0,
            "tips" => [],
            "coordinates" => [],
            "entry_ids" => []
          }
        })
      ])

    assert {:error, :log_mismatch} =
             CloudflareSidecar.read_set(store(transport), "log-a", %{
               writers: [],
               coordinates: [],
               entry_ids: []
             })
  end

  test "all wire storage codes have explicit mappings" do
    mappings = [
      {400, "malformed_request", :malformed_request},
      {409, "constraint_violation", :constraint_violation},
      {507, "storage_full", :storage_full},
      {409, "log_mismatch", :log_mismatch}
    ]

    for {status, code, expected} <- mappings do
      {:ok, transport} = TransportDouble.start_link([error_response(status, code)])
      assert {:error, ^expected} = CloudflareSidecar.commit(store(transport), empty_plan())
    end
  end

  test "malformed and unexpected responses fail as protocol errors" do
    cases = [
      {:ok, %{status: 200, headers: [], body: "{"}},
      {:ok, %{status: 200, body: Jason.encode!(%{"ok" => true, "revision" => 1})}},
      response(200, %{"ok" => true}),
      response(201, %{"ok" => true, "revision" => 1}),
      response(409, %{"ok" => false, "error" => %{"code" => "mystery"}})
    ]

    for response <- cases do
      {:ok, transport} = TransportDouble.start_link([response])

      assert {:error, {:protocol_error, _reason}} =
               CloudflareSidecar.commit(store(transport), empty_plan())
    end
  end

  test "HTTP 500 and refused connections are transport errors, not storage errors" do
    for response <- [
          {:ok, %{status: 500, headers: [], body: "upstream failed"}},
          {:error, :econnrefused}
        ] do
      {:ok, transport} = TransportDouble.start_link([response])

      assert {:error, {:transport_error, _reason}} =
               CloudflareSidecar.frontier(store(transport), "log-a")
    end
  end

  test "the transport seam can report a lost acknowledgement after applying a side effect" do
    test_pid = self()

    store =
      CloudflareSidecar.new("https://sidecar.example",
        transport: LostAckTransport,
        transport_options: test_pid
      )

    assert {:error, {:transport_error, :ack_lost}} = CloudflareSidecar.commit(store, empty_plan())
    assert_received :commit_applied
  end

  test "the real httpc transport starts its OTP applications and reports a refused connection" do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {{127, 0, 0, 1}, port}} = :inet.sockname(listener)
    :ok = :gen_tcp.close(listener)

    store =
      CloudflareSidecar.new("http://127.0.0.1:#{port}",
        transport_options: [timeout: 1_000, connect_timeout: 1_000]
      )

    assert {:error, {:transport_error, _reason}} = CloudflareSidecar.frontier(store, "probe")
  end

  defp store(transport) do
    CloudflareSidecar.new("https://sidecar.example",
      transport: TransportDouble,
      transport_options: transport
    )
  end

  defp empty_plan do
    %CommitPlan{log_id: "log-a", expected_revision: 0, expected_epoch: 0}
  end

  defp response(status, body) do
    {:ok,
     %{status: status, headers: [{"content-type", "application/json"}], body: Jason.encode!(body)}}
  end

  defp error_response(status, code) do
    response(status, %{"ok" => false, "error" => %{"code" => code}})
  end

  defp assert_request(request, path, body) do
    assert request.method == :post
    assert request.url == "https://sidecar.example" <> path
    assert request.headers == [{"content-type", "application/json"}]
    assert request.body == body
  end
end
