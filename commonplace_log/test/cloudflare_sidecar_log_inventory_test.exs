defmodule Commonplace.Log.Persistence.CloudflareSidecarLogInventoryTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.Persistence.CloudflareSidecar

  defmodule InventoryTransport do
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

    def requests(pid), do: Agent.get(pid, fn {_responses, requests} -> Enum.reverse(requests) end)
  end

  defmodule RaiseTransport do
    @behaviour Commonplace.Log.Persistence.CloudflareSidecar.Transport
    @impl true
    def request(_method, _url, _headers, _body, _options), do: raise("transport secret")
  end

  defmodule ThrowTransport do
    @behaviour Commonplace.Log.Persistence.CloudflareSidecar.Transport
    @impl true
    def request(_method, _url, _headers, _body, _options), do: throw({:transport, "secret"})
  end

  defmodule ExitTransport do
    @behaviour Commonplace.Log.Persistence.CloudflareSidecar.Transport
    @impl true
    def request(_method, _url, _headers, _body, _options), do: exit({:transport, "secret"})
  end

  @generation String.duplicate("a", 64)
  @safe_integer 9_007_199_254_740_991

  test "parses an empty inventory and emits the bounded request" do
    {:ok, transport} = InventoryTransport.start_link([response(200, success([]))])

    assert {:ok, %{generation: @generation, logs: []}} =
             CloudflareSidecar.list_log_inventory(store(transport), 1)

    assert [%{method: :post, url: "https://sidecar.example/list-logs", body: %{"max_logs" => 1}}] =
             InventoryTransport.requests(transport)
  end

  test "parses mixed metadata, nullable document writer, and sorted writer tips" do
    logs = [
      %{
        "log_id" => "log-a",
        "format_version" => 1,
        "revision" => 0,
        "created_at" => "2026-09-12T00:00:00Z",
        "document_writer_id" => nil,
        "writers" => []
      },
      %{
        "log_id" => "log-b",
        "format_version" => 1,
        "revision" => 4,
        "created_at" => "2026-09-12T00:00:01Z",
        "document_writer_id" => "document-writer",
        "writers" => [
          %{"writer_id" => "writer-a", "last_seq" => 2, "last_entry_id" => "entry-a"},
          %{"writer_id" => "writer-b", "last_seq" => 7, "last_entry_id" => "entry-b"}
        ]
      }
    ]

    {:ok, transport} = InventoryTransport.start_link([response(200, success(logs))])

    assert {:ok,
            %{
              generation: @generation,
              logs: [
                %{log_id: "log-a", document_writer_id: nil, writers: []},
                %{
                  log_id: "log-b",
                  revision: 4,
                  document_writer_id: "document-writer",
                  writers: writers
                }
              ]
            }} = CloudflareSidecar.list_log_inventory(store(transport))

    assert writers == [
             %{writer_id: "writer-a", last_seq: 2, last_entry_id: "entry-a"},
             %{writer_id: "writer-b", last_seq: 7, last_entry_id: "entry-b"}
           ]
  end

  test "rejects max log counts outside the provider bound without transport" do
    {:ok, transport} = InventoryTransport.start_link([])

    for value <- [0, 65, "64", nil] do
      assert {:error, :invalid_inventory_limit} =
               CloudflareSidecar.list_log_inventory(store(transport), value)
    end

    assert InventoryTransport.requests(transport) == []
  end

  test "rejects unknown fields, duplicate rows, and unsorted rows" do
    cases = [
      put_in(success([]), ["extra"], true),
      %{"ok" => true, "result" => %{"generation" => @generation, "logs" => [%{"log_id" => "x"}]}},
      success([Map.put(log("a"), "extra", true)]),
      success([
        Map.update!(log("a"), "writers", fn _ ->
          [%{"writer_id" => "w", "last_seq" => 1, "last_entry_id" => "e", "extra" => true}]
        end)
      ]),
      success([log("a"), log("a")]),
      success([log("b"), log("a")]),
      success([Map.update!(log("a"), "writers", fn _ -> [writer("w"), writer("w")] end)]),
      success([Map.update!(log("a"), "writers", fn _ -> [writer("w2"), writer("w1")] end)])
    ]

    for body <- cases do
      {:ok, transport} = InventoryTransport.start_link([response(200, body)])

      assert {:error, {:protocol_error, :invalid_response}} =
               CloudflareSidecar.list_log_inventory(store(transport))
    end
  end

  test "rejects malformed numbers, digest, and bounded strings" do
    cases = [
      put_in(success([]), ["result", "generation"], String.duplicate("A", 64)),
      put_in(success([]), ["result", "generation"], String.duplicate("a", 63)),
      success([Map.put(log("a"), "format_version", 0)]),
      success([Map.put(log("a"), "format_version", @safe_integer + 1)]),
      success([Map.put(log("a"), "revision", -1)]),
      success([Map.put(log("a"), "revision", @safe_integer + 1)]),
      success([
        Map.update!(log("a"), "writers", fn _ -> [Map.put(writer("w"), "last_seq", 0)] end)
      ]),
      success([
        Map.update!(log("a"), "writers", fn _ ->
          [Map.put(writer("w"), "last_seq", @safe_integer + 1)]
        end)
      ]),
      success([Map.put(log("a"), "log_id", String.duplicate("x", 257))]),
      success([Map.put(log("a"), "created_at", "")]),
      success([
        Map.update!(log("a"), "writers", fn _ -> [Map.put(writer("w"), "last_entry_id", "")] end)
      ])
    ]

    for body <- cases do
      {:ok, transport} = InventoryTransport.start_link([response(200, body)])

      assert {:error, {:protocol_error, :invalid_response}} =
               CloudflareSidecar.list_log_inventory(store(transport))
    end
  end

  test "enforces response log, writer, and raw JSON bounds" do
    {:ok, transport} =
      InventoryTransport.start_link([response(200, success([log("a"), log("b")]))])

    assert {:error, {:protocol_error, :invalid_response}} =
             CloudflareSidecar.list_log_inventory(store(transport), 1)

    writers = Enum.map(1..4_097, fn index -> writer("w#{index}") end)

    {:ok, transport} =
      InventoryTransport.start_link([
        response(200, success([Map.put(log("a"), "writers", writers)]))
      ])

    assert {:error, {:protocol_error, :invalid_response}} =
             CloudflareSidecar.list_log_inventory(store(transport))

    {:ok, transport} =
      InventoryTransport.start_link([
        {:ok, %{status: 200, body: String.duplicate("x", 256 * 1024 + 1)}}
      ])

    assert {:error, {:protocol_error, :invalid_response}} =
             CloudflareSidecar.list_log_inventory(store(transport))
  end

  test "closes transport raise, throw, and exit paths without leaking exceptions" do
    for transport <- [RaiseTransport, ThrowTransport, ExitTransport] do
      error =
        CloudflareSidecar.list_log_inventory(
          CloudflareSidecar.new("https://sidecar.example", transport: transport)
        )

      assert error == {:error, {:transport_error, :transport_failed}}
      refute inspect(error) =~ "secret"
    end
  end

  test "maps inventory status errors without leaking response details" do
    for {status, code, expected} <- [
          {400, "malformed", :malformed},
          {409, "constraint", :constraint},
          {409, "obsolete_epoch", :obsolete_epoch},
          {413, "oversize", :oversize},
          {507, "storage_full", :storage_full}
        ] do
      {:ok, transport} =
        InventoryTransport.start_link([error_response(status, code, "response secret")])

      error = CloudflareSidecar.list_log_inventory(store(transport))
      assert error == {:error, {:provider_error, expected}}
      refute inspect(error) =~ "response secret"
    end

    for status <- [401, 403] do
      {:ok, transport} =
        InventoryTransport.start_link([error_response(status, "unauthorized", "response secret")])

      assert {:error, {:unauthorized, :provider_rejected}} =
               CloudflareSidecar.list_log_inventory(store(transport))
    end

    {:ok, transport} =
      InventoryTransport.start_link([error_response(500, "internal", "response secret")])

    assert {:error, {:transport_error, :provider_failed}} =
             CloudflareSidecar.list_log_inventory(store(transport))

    {:ok, transport} =
      InventoryTransport.start_link([
        response(409, %{"ok" => false, "error" => %{"code" => "constraint", "extra" => "secret"}})
      ])

    assert {:error, {:protocol_error, :invalid_response}} =
             CloudflareSidecar.list_log_inventory(store(transport))
  end

  defp store(transport),
    do:
      CloudflareSidecar.new("https://sidecar.example",
        transport: InventoryTransport,
        transport_options: transport
      )

  defp success(logs),
    do: %{"ok" => true, "result" => %{"generation" => @generation, "logs" => logs}}

  defp log(id),
    do: %{
      "log_id" => id,
      "format_version" => 1,
      "revision" => 0,
      "created_at" => "2026-09-12T00:00:00Z",
      "document_writer_id" => nil,
      "writers" => []
    }

  defp writer(id), do: %{"writer_id" => id, "last_seq" => 1, "last_entry_id" => "entry-" <> id}

  defp response(status, body),
    do: {:ok, %{status: status, headers: [], body: Jason.encode!(body)}}

  defp error_response(status, code, _detail),
    do: response(status, %{"ok" => false, "error" => %{"code" => code}})
end
