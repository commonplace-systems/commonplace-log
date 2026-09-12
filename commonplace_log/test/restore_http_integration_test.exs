defmodule Commonplace.Log.RestoreHTTPIntegrationTest do
  use ExUnit.Case, async: false

  alias Commonplace.Log.Jcs
  alias Commonplace.Log.Persistence.CloudflareSidecar
  alias Commonplace.Log.Persistence.CloudflareSidecar.Httpc

  @realm_id "61000000-0000-4000-8000-000000000001"
  @log_a "61000000-0000-4000-8000-000000000011"
  @log_b "61000000-0000-4000-8000-000000000012"
  @writer_a "61000000-0000-4000-8000-000000000021"
  @writer_b "61000000-0000-4000-8000-000000000022"

  test "real Httpc reaches fixed local DO restore wire and exact readback" do
    base_url = System.fetch_env!("RESTORE_HTTP_BASE_URL")
    headers = [{"content-type", "application/json"}]

    assert {:ok, %{status: 400, body: malformed}} =
             Httpc.request(:post, base_url <> "/create-log", headers, "{", timeout: 5_000)

    assert %{"ok" => false, "error" => %{"code" => "malformed_request"}} =
             Jason.decode!(malformed)

    assert {:ok, %{status: 201, body: provisioned}} =
             Httpc.request(
               :post,
               base_url <> "/realm/create",
               [
                 {"x-commonplace-realm-create", "1"},
                 {"x-commonplace-realm-id", @realm_id} | headers
               ],
               "{}",
               timeout: 5_000
             )

    assert %{"ok" => true, "realm_id" => @realm_id} = Jason.decode!(provisioned)

    store =
      CloudflareSidecar.new(base_url, transport_options: [timeout: 5_000, connect_timeout: 5_000])

    source = bundle()
    ordinary_metadata = %{format_version: 1, created_at: "2026-09-12T00:00:00Z"}

    assert {:ok, %{imported_logs: 1, skipped_logs: 0, complete: false}} =
             CloudflareSidecar.restore_bundle_batch(store, source, 1)

    assert {:error, :obsolete_epoch} =
             CloudflareSidecar.create_log(
               store,
               "61000000-0000-4000-8000-000000000099",
               ordinary_metadata
             )

    assert {:error, :obsolete_epoch} = CloudflareSidecar.take_lease(store, @log_a)

    assert {:ok, %{imported_logs: 1, skipped_logs: 1, complete: true}} =
             CloudflareSidecar.restore_bundle_batch(store, source, 1)

    assert {:ok, %{entries: entries_a, next_after_seq: nil}} =
             CloudflareSidecar.read_writer(store, @log_a, @writer_a, after_seq: 0, limit: 10)

    assert {:ok, %{entries: entries_b, next_after_seq: nil}} =
             CloudflareSidecar.read_writer(store, @log_b, @writer_b, after_seq: 0, limit: 10)

    assert Enum.map(entries_a, & &1.canonical_bytes) ==
             source.logs |> Enum.at(0) |> Map.fetch!(:entries)

    assert Enum.map(entries_b, & &1.canonical_bytes) ==
             source.logs |> Enum.at(1) |> Map.fetch!(:entries)

    assert {:ok, %{imported_logs: 0, skipped_logs: 2, complete: true}} =
             CloudflareSidecar.restore_bundle_batch(store, source, 1)

    IO.puts(
      "RESTORE_HTTP_WORKFLOW requests=9 logs=2 entries=4 partial_resume_complete=true exact_readback=true idempotent_replay=true"
    )
  end

  defp bundle do
    %{
      bundle_id: "restore-http-bundle-1",
      logs: [
        %{
          log_id: @log_a,
          archive_id: "61000000-0000-4000-8000-000000000031",
          writer_id: @writer_a,
          entries: [
            entry(@log_a, @writer_a, "61000000-0000-4000-8000-000000000041", 1, nil),
            entry(
              @log_a,
              @writer_a,
              "61000000-0000-4000-8000-000000000042",
              2,
              "61000000-0000-4000-8000-000000000041"
            )
          ]
        },
        %{
          log_id: @log_b,
          archive_id: "61000000-0000-4000-8000-000000000032",
          writer_id: @writer_b,
          entries: [
            entry(@log_b, @writer_b, "61000000-0000-4000-8000-000000000043", 1, nil),
            entry(
              @log_b,
              @writer_b,
              "61000000-0000-4000-8000-000000000044",
              2,
              "61000000-0000-4000-8000-000000000043"
            )
          ]
        }
      ]
    }
  end

  defp entry(log_id, writer_id, entry_id, sequence, previous) do
    Jcs.canonicalize(%{
      "version" => 1,
      "log_id" => log_id,
      "entry_id" => entry_id,
      "writer_id" => writer_id,
      "writer_seq" => sequence,
      "prev_entry_id" => previous,
      "created_at" => "2026-09-12T00:00:00Z",
      "body" => %{"integration" => true, "sequence" => sequence}
    })
  end
end
