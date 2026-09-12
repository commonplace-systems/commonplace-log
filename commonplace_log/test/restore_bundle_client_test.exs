defmodule Commonplace.Log.Persistence.CloudflareSidecarRestoreBundleTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.Jcs
  alias Commonplace.Log.Persistence.CloudflareSidecar

  defmodule Transport do
    @behaviour Commonplace.Log.Persistence.CloudflareSidecar.Transport

    @impl true
    def request(:post, url, _headers, body, {owner, response}) do
      send(owner, {:restore_request, url, Jason.decode!(body)})

      case response do
        :raise -> raise("transport secret")
        :throw -> throw("transport secret")
        :exit -> exit("transport secret")
        response -> response
      end
    end
  end

  @log_a "018f5e2a-8b3c-7d4e-9f10-123456789aaa"
  @log_b "018f5e2a-8b3c-7d4e-9f10-123456789aab"
  @writer "018f5e2a-8b3c-7d4e-9f10-123456789abd"

  test "encodes canonical entries, sends the complete sorted inventory, and parses result" do
    store = sidecar(self(), response(200, %{"ok" => true, "result" => result(1, 0, false)}))

    assert {:ok, %{imported_logs: 1, skipped_logs: 0, complete: false}} =
             CloudflareSidecar.restore_bundle_batch(store, bundle(), 1)

    assert_receive {:restore_request, "https://sidecar.example/restore-bundle-batch", body}
    assert body["bundle_id"] == "bundle-1"
    assert body["max_logs"] == 1
    assert Enum.map(body["logs"], & &1["log_id"]) == [@log_a, @log_b]
    assert Enum.all?(body["logs"], &is_binary(hd(&1["entries"])))
    refute Map.has_key?(body, "realm_id")
    refute Map.has_key?(body, "target")
  end

  test "rejects invalid inventory before transport" do
    store = sidecar(self(), response(200, %{"ok" => true, "result" => result(0, 0, true)}))
    malformed = %{bundle_id: "bundle-1", logs: Enum.map(1..65, &log(@log_a, "archive-#{&1}"))}

    assert {:error, {:invalid_restore_bundle, :invalid_shape}} =
             CloudflareSidecar.restore_bundle_batch(store, malformed)

    refute_received {:restore_request, _, _}
  end

  @tag :restore_oversized_response
  test "rejects an oversized successful response without exposing its body" do
    oversized = String.duplicate("x", 4_097)

    store =
      sidecar(
        self(),
        response(200, %{"ok" => true, "result" => result(0, 0, true), "pad" => oversized})
      )

    assert {:error, {:protocol_error, :invalid_response}} =
             CloudflareSidecar.restore_bundle_batch(store, bundle())
  end

  test "rejects a success response with provider-shaped or secret keys as one closed protocol error" do
    store =
      sidecar(
        self(),
        response(200, %{
          "ok" => true,
          "result" => result(1, 0, false) |> Map.put("secret", "sentinel")
        })
      )

    assert {:error, {:protocol_error, :invalid_response}} =
             CloudflareSidecar.restore_bundle_batch(store, bundle(), 1)
  end

  test "preflights raw entry and aggregate bounds before validation or transport" do
    raw = :binary.copy(<<0>>, 1_000_000)

    oversized = %{
      bundle_id: "bundle-oversized-raw",
      logs:
        Enum.map(0..16, fn index ->
          id =
            "018f5e2a-8b3c-7d4e-9f10-123456789#{String.pad_leading(Integer.to_string(index), 3, "0")}"

          %{log_id: id, archive_id: "archive-#{index}", writer_id: @writer, entries: [raw]}
        end)
    }

    store = sidecar(self(), response(200, %{"ok" => true, "result" => result(0, 0, true)}))

    assert {:error, {:invalid_restore_bundle, :invalid_shape}} =
             CloudflareSidecar.restore_bundle_batch(store, oversized)

    refute_received {:restore_request, _, _}
  end

  test "closes transport exceptions and inconsistent result counts" do
    for failure <- [:raise, :throw, :exit] do
      assert {:error, {:transport_error, :transport_failed}} =
               CloudflareSidecar.restore_bundle_batch(sidecar(self(), failure), bundle())
    end

    inconsistent = sidecar(self(), response(200, %{"ok" => true, "result" => result(2, 0, true)}))

    assert {:error, {:protocol_error, :invalid_response}} =
             CloudflareSidecar.restore_bundle_batch(inconsistent, bundle(), 1)
  end

  test "maps provider failures without returning body or URL" do
    cases = [
      {400, %{"ok" => false, "error" => %{"code" => "malformed"}}, {:provider_error, :malformed}},
      {401, %{"secret" => "sentinel"}, {:unauthorized, :provider_rejected}},
      {500, %{"secret" => "sentinel"}, {:transport_error, :provider_failed}},
      {409, %{"ok" => false, "error" => %{"code" => "constraint"}},
       {:provider_error, :constraint}}
    ]

    for {status, body, reason} <- cases do
      assert {:error, ^reason} =
               CloudflareSidecar.restore_bundle_batch(
                 sidecar(self(), response(status, body)),
                 bundle()
               )
    end
  end

  defp bundle do
    %{bundle_id: "bundle-1", logs: [log(@log_a, "archive-a"), log(@log_b, "archive-b")]}
  end

  defp log(log_id, archive_id) do
    %{
      log_id: log_id,
      archive_id: archive_id,
      writer_id: @writer,
      entries: [entry(log_id, 1, nil)]
    }
  end

  defp entry(log_id, sequence, previous) do
    Jcs.canonicalize(%{
      "version" => 1,
      "log_id" => log_id,
      "entry_id" => "018f5e2a-8b3c-7d4e-9f10-123456789ac#{sequence}",
      "writer_id" => @writer,
      "writer_seq" => sequence,
      "prev_entry_id" => previous,
      "created_at" => "2026-09-12T00:00:00Z",
      "body" => %{"restore" => true}
    })
  end

  defp result(imported, skipped, complete),
    do: %{"imported_logs" => imported, "skipped_logs" => skipped, "complete" => complete}

  defp response(status, body),
    do:
      {:ok,
       %{
         status: status,
         headers: [{"content-type", "application/json"}],
         body: Jason.encode!(body)
       }}

  defp sidecar(owner, response) do
    CloudflareSidecar.new("https://sidecar.example/",
      transport: Transport,
      transport_options: {owner, response}
    )
  end
end
