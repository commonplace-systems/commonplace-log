defmodule Commonplace.Log.LogInventoryHTTPIntegrationTest do
  use ExUnit.Case, async: false

  alias Commonplace.Log.Jcs
  alias Commonplace.Log.Persistence.{CloudflareSidecar, CommitPlan}
  alias Commonplace.Log.Persistence.CloudflareSidecar.Httpc

  @realm_id "61000000-0000-4000-8000-000000000101"
  @log_a "61000000-0000-4000-8000-000000000111"
  @log_b "61000000-0000-4000-8000-000000000112"
  @log_c "61000000-0000-4000-8000-000000000113"
  @writer_a "61000000-0000-4000-8000-000000000121"
  @writer_b "61000000-0000-4000-8000-000000000122"

  test "real Httpc inventory follows restore, replay, and ordinary commit" do
    base_url = System.fetch_env!("LOG_INVENTORY_HTTP_BASE_URL")
    headers = [{"content-type", "application/json"}]

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
      CloudflareSidecar.new(base_url,
        transport_options: [timeout: 5_000, connect_timeout: 5_000]
      )

    assert {:ok, %{generation: initial_generation, logs: []}} =
             CloudflareSidecar.list_log_inventory(store)

    source = bundle()

    assert {:ok, %{imported_logs: 1, skipped_logs: 0, complete: false}} =
             CloudflareSidecar.restore_bundle_batch(store, source, 1)

    assert {:error, {:provider_error, :obsolete_epoch}} =
             CloudflareSidecar.list_log_inventory(store)

    assert {:ok, %{imported_logs: 1, skipped_logs: 1, complete: true}} =
             CloudflareSidecar.restore_bundle_batch(store, source, 1)

    assert {:ok, %{generation: restored_generation, logs: restored_logs}} =
             CloudflareSidecar.list_log_inventory(store)

    assert restored_generation != initial_generation
    assert Enum.map(restored_logs, & &1.log_id) == [@log_a, @log_b]
    assert Enum.map(restored_logs, & &1.format_version) == [1, 1]
    assert Enum.map(restored_logs, & &1.revision) == [0, 0]
    assert Enum.map(restored_logs, & &1.document_writer_id) == [@writer_a, @writer_b]
    assert Enum.map(restored_logs, & &1.writers) == [
             [%{writer_id: @writer_a, last_seq: 2, last_entry_id: "61000000-0000-4000-8000-000000000142"}],
             [%{writer_id: @writer_b, last_seq: 2, last_entry_id: "61000000-0000-4000-8000-000000000144"}]
           ]
    assert Enum.all?(restored_logs, &Regex.match?(~r/^20\d\d-\d\d-\d\dT.*Z$/, &1.created_at))

    assert {:ok, %{imported_logs: 0, skipped_logs: 2, complete: true}} =
             CloudflareSidecar.restore_bundle_batch(store, source, 1)

    assert {:ok, %{generation: ^restored_generation, logs: ^restored_logs}} =
             CloudflareSidecar.list_log_inventory(store)

    assert :ok =
             CloudflareSidecar.create_log(store, @log_c, %{
               format_version: 1,
               created_at: "2026-09-13T00:00:00Z"
             })

    assert {:ok, %{generation: after_create_generation, logs: after_create_logs}} =
             CloudflareSidecar.list_log_inventory(store)

    assert after_create_generation != restored_generation
    assert Enum.map(after_create_logs, & &1.log_id) == [@log_a, @log_b, @log_c]

    assert {:ok, %{lease_epoch: lease_epoch, writer_id: writer_id}} =
             CloudflareSidecar.take_lease(store, @log_c)

    canonical = entry(@log_c, writer_id, "61000000-0000-4000-8000-000000000151", 1, nil, "2026-09-13T00:00:01Z")

    plan = %CommitPlan{
      log_id: @log_c,
      expected_revision: 0,
      expected_epoch: lease_epoch,
      insert_entries: [
        %{
          log_id: @log_c,
          entry_id: "61000000-0000-4000-8000-000000000151",
          writer_id: writer_id,
          writer_seq: 1,
          prev_entry_id: nil,
          created_at: "2026-09-13T00:00:01Z",
          canonical_bytes: canonical
        }
      ],
      put_tips: [%{writer_id: writer_id, seq: 1, entry_id: "61000000-0000-4000-8000-000000000151"}]
    }

    assert {:ok, 1} = CloudflareSidecar.commit(store, plan)

    assert {:ok, %{entries: [%{canonical_bytes: ^canonical, writer_seq: 1}], next_after_seq: nil}} =
             CloudflareSidecar.read_writer(store, @log_c, writer_id, after_seq: 0, limit: 10)

    assert {:ok, %{generation: final_generation, logs: final_logs}} =
             CloudflareSidecar.list_log_inventory(store)

    assert final_generation != after_create_generation
    assert Enum.find(final_logs, &(&1.log_id == @log_c)) == %{
             log_id: @log_c,
             format_version: 1,
             revision: 1,
             created_at: "2026-09-13T00:00:00Z",
             document_writer_id: writer_id,
             writers: [%{writer_id: writer_id, last_seq: 1, last_entry_id: "61000000-0000-4000-8000-000000000151"}]
           }

    IO.puts(
      "LOG_INVENTORY_HTTP_WORKFLOW requests=13 logs=3 partial_obsolete=true replay_stable=true exact_commit_readback=true generation_changes=true"
    )
  end

  defp bundle do
    %{
      bundle_id: "log-inventory-http-bundle-1",
      logs: [
        %{
          log_id: @log_a,
          archive_id: "61000000-0000-4000-8000-000000000131",
          writer_id: @writer_a,
          entries: [
            entry(@log_a, @writer_a, "61000000-0000-4000-8000-000000000141", 1, nil),
            entry(@log_a, @writer_a, "61000000-0000-4000-8000-000000000142", 2, "61000000-0000-4000-8000-000000000141")
          ]
        },
        %{
          log_id: @log_b,
          archive_id: "61000000-0000-4000-8000-000000000132",
          writer_id: @writer_b,
          entries: [
            entry(@log_b, @writer_b, "61000000-0000-4000-8000-000000000143", 1, nil),
            entry(@log_b, @writer_b, "61000000-0000-4000-8000-000000000144", 2, "61000000-0000-4000-8000-000000000143")
          ]
        }
      ]
    }
  end

  defp entry(log_id, writer_id, entry_id, sequence, previous, created_at \\ "2026-09-13T00:00:00Z") do
    Jcs.canonicalize(%{
      "version" => 1,
      "log_id" => log_id,
      "entry_id" => entry_id,
      "writer_id" => writer_id,
      "writer_seq" => sequence,
      "prev_entry_id" => previous,
      "created_at" => created_at,
      "body" => %{"inventory_http" => true, "sequence" => sequence}
    })
  end
end
