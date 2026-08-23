defmodule Commonplace.Log.Persistence.LostAcknowledgementTest do
  use ExUnit.Case, async: true

  alias Commonplace.Log.Engine
  alias Commonplace.Log.Persistence.{CloudflareSidecar, CommitPlan}
  alias Commonplace.Log.Test.InMemoryPersistence

  @log_id "018f5e2a-8b3c-7d4e-9f10-123456789abc"
  @writer_id "018f5e2a-8b3c-7d4e-9f10-123456789abd"
  @entry_id "018f5e2a-8b3c-7d4e-9f10-123456789abe"
  @created_at ~U[2026-08-23 12:34:56Z]

  defmodule RealStoreTransport do
    @behaviour Commonplace.Log.Persistence.CloudflareSidecar.Transport

    alias Commonplace.Log.Persistence.CommitPlan
    alias Commonplace.Log.Test.InMemoryPersistence

    def start_link(store, faults) do
      Agent.start_link(fn -> %{store: store, faults: faults} end)
    end

    @impl true
    def request(:post, url, _headers, body, transport) do
      path = URI.parse(url).path
      payload = Jason.decode!(body)

      Agent.get_and_update(transport, fn state ->
        {fault, faults} = pop_fault(state.faults, path)
        result = dispatch(state.store, path, payload, fault)
        {result, %{state | faults: faults}}
      end)
    end

    defp dispatch(_store, _path, _payload, :before_apply), do: {:error, :before_apply}

    defp dispatch(store, path, payload, fault) do
      response = apply_request(store, path, payload)

      case fault do
        :after_apply -> {:error, :ack_lost}
        :pass -> response
      end
    end

    defp apply_request(store, "/commit", payload) do
      plan = %CommitPlan{
        log_id: payload["log_id"],
        expected_revision: payload["expected_revision"],
        expected_epoch: payload["expected_epoch"],
        insert_entries: Enum.map(payload["insert_entries"], &decode_entry/1),
        put_tips: Enum.map(payload["put_tips"], &decode_tip/1)
      }

      case InMemoryPersistence.commit(store, plan) do
        {:ok, revision} -> response(200, %{"ok" => true, "revision" => revision})
        {:error, :stale_revision} -> error_response(409, "stale_revision")
        {:error, :obsolete_epoch} -> error_response(409, "obsolete_epoch")
      end
    end

    defp apply_request(store, "/read-set", payload) do
      query = %{
        writers: payload["writers"],
        coordinates: Enum.map(payload["coordinates"], &{&1["writer_id"], &1["writer_seq"]}),
        entry_ids: payload["entry_ids"]
      }

      case InMemoryPersistence.read_set(store, payload["log_id"], query) do
        {:ok, read_set} -> response(200, %{"ok" => true, "read_set" => encode(read_set)})
        {:error, :not_found} -> error_response(404, "not_found")
      end
    end

    defp encode(read_set) do
      %{
        "log_id" => read_set.log_id,
        "format_version" => 1,
        "revision" => read_set.revision,
        "lease_epoch" => read_set.lease_epoch,
        "tips" =>
          Enum.map(read_set.tips, fn {writer_id, tip} ->
            %{
              "writer_id" => writer_id,
              "last_seq" => tip.seq,
              "last_entry_id" => tip.entry_id
            }
          end),
        "coordinates" =>
          Enum.map(read_set.coordinates, fn {{writer_id, writer_seq}, bytes} ->
            %{
              "writer_id" => writer_id,
              "writer_seq" => writer_seq,
              "canonical_bytes" => Base.encode64(bytes)
            }
          end),
        "entry_ids" =>
          Enum.map(read_set.entry_ids, fn {entry_id, bytes} ->
            %{"entry_id" => entry_id, "canonical_bytes" => Base.encode64(bytes)}
          end)
      }
    end

    defp decode_entry(row) do
      %{
        log_id: row["log_id"],
        entry_id: row["entry_id"],
        writer_id: row["writer_id"],
        writer_seq: row["writer_seq"],
        prev_entry_id: row["prev_entry_id"],
        created_at: row["created_at"],
        canonical_bytes: Base.decode64!(row["canonical_bytes"])
      }
    end

    defp decode_tip(row) do
      %{
        writer_id: row["writer_id"],
        seq: row["last_seq"],
        entry_id: row["last_entry_id"]
      }
    end

    defp pop_fault(faults, path) do
      case Map.get(faults, path, []) do
        [fault | rest] -> {fault, Map.put(faults, path, rest)}
        [] -> {:pass, faults}
      end
    end

    defp response(status, body) do
      {:ok,
       %{
         status: status,
         headers: [{"content-type", "application/json"}],
         body: Jason.encode!(body)
       }}
    end

    defp error_response(status, code) do
      response(status, %{"ok" => false, "error" => %{"code" => code}})
    end
  end

  setup do
    {:ok, base} = InMemoryPersistence.start_link()
    :ok = InMemoryPersistence.create_log(base, @log_id, %{})
    %{base: base}
  end

  test "commit acknowledgement lost after apply is reconciled as exactly one success", %{
    base: base
  } do
    store = sidecar(base, %{commit: [:after_apply]})

    assert {:ok, 1} = CloudflareSidecar.commit(store, plan())
    assert_single_effect(base, @entry_id)
  end

  test "Engine.append acknowledgement lost after apply has one logical effect", %{base: base} do
    store = sidecar(base, %{commit: [:after_apply]})

    result =
      retry_logical_append_once(fn ->
        Engine.append(
          CloudflareSidecar,
          store,
          @log_id,
          @writer_id,
          %{"kind" => "lost-ack"},
          @created_at
        )
      end)

    assert {:ok, %{entry_id: entry_id}} = result
    assert [%{entry_id: ^entry_id, writer_seq: 1}] = Map.values(snapshot(base).entries)
    assert %{writer_seq: 1, revision: 1} = elem(result, 1)
    assert_single_effect(base, entry_id)
  end

  test "commit transport failure before apply reports failure and writes nothing", %{base: base} do
    store = sidecar(base, %{commit: [:before_apply]})

    assert {:error, {:transport_error, :before_apply}} =
             CloudflareSidecar.commit(store, plan())

    assert %{entries: %{}, revision: 0, arrival_seq: 0} = snapshot(base)
  end

  test "Engine.append transport failure before apply reports failure and writes nothing", %{
    base: base
  } do
    store = sidecar(base, %{commit: [:before_apply]})

    assert {:error, {:transport_error, :before_apply}} =
             Engine.append(
               CloudflareSidecar,
               store,
               @log_id,
               @writer_id,
               %{"kind" => "failed-before-apply"},
               @created_at
             )

    assert %{entries: %{}, revision: 0, arrival_seq: 0} = snapshot(base)
  end

  test "ordinary successful commit is unaffected", %{base: base} do
    assert {:ok, 1} = CloudflareSidecar.commit(sidecar(base), plan())
    assert_single_effect(base, @entry_id)
  end

  test "two consecutive lost acknowledgements still have exactly one logical effect", %{
    base: base
  } do
    store = sidecar(base, %{commit: [:after_apply], read_set: [:pass, :after_apply]})

    assert {:ok, %{entry_id: entry_id, writer_seq: 1, revision: 1}} =
             Engine.append(
               CloudflareSidecar,
               store,
               @log_id,
               @writer_id,
               %{"kind" => "two-lost-acks"},
               @created_at
             )

    assert_single_effect(base, entry_id)
  end

  test "an undeterminable commit outcome is explicit and is never guessed", %{base: base} do
    store =
      sidecar(base, %{
        commit: [:after_apply],
        read_set: [:before_apply, :before_apply, :before_apply]
      })

    assert {:error, {:commit_outcome_unknown, details}} =
             CloudflareSidecar.commit(store, plan())

    assert details.commit_error == {:transport_error, :ack_lost}
    assert details.reconciliation_error == {:transport_error, :before_apply}
    assert_single_effect(base, @entry_id)
  end

  defp sidecar(base, faults \\ %{}) do
    faults =
      Map.new(faults, fn
        {:commit, values} -> {"/commit", values}
        {:read_set, values} -> {"/read-set", values}
      end)

    {:ok, transport} = RealStoreTransport.start_link(base, faults)

    CloudflareSidecar.new("https://sidecar.example",
      transport: RealStoreTransport,
      transport_options: transport
    )
  end

  defp plan do
    %CommitPlan{
      log_id: @log_id,
      expected_revision: 0,
      expected_epoch: 0,
      insert_entries: [
        %{
          log_id: @log_id,
          entry_id: @entry_id,
          writer_id: @writer_id,
          writer_seq: 1,
          prev_entry_id: nil,
          created_at: "2026-08-23T12:34:56Z",
          canonical_bytes: "canonical-entry"
        }
      ],
      put_tips: [%{writer_id: @writer_id, seq: 1, entry_id: @entry_id}]
    }
  end

  defp retry_logical_append_once(fun) do
    case fun.() do
      {:error, {:transport_error, _reason}} -> fun.()
      result -> result
    end
  end

  defp assert_single_effect(base, entry_id) do
    log = snapshot(base)
    assert map_size(log.entries) == 1
    assert [{@writer_id, 1}] = Map.keys(log.entries)
    assert %{entry_id: ^entry_id, writer_seq: 1, arrival_seq: 1} = log.entries[{@writer_id, 1}]
    assert log.revision == 1
    assert log.arrival_seq == 1
  end

  defp snapshot(base), do: InMemoryPersistence.snapshot(base, @log_id)
end
