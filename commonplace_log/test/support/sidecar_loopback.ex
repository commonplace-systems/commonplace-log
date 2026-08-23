defmodule Commonplace.Log.Test.SidecarLoopback do
  @moduledoc "HTTP-shaped loopback transport backed by a Persistence adapter."

  @behaviour Commonplace.Log.Persistence.CloudflareSidecar.Transport

  alias Commonplace.Log.Persistence.CommitPlan

  @impl true
  def request(:post, url, _headers, body, {module, store}) do
    url
    |> URI.parse()
    |> Map.fetch!(:path)
    |> dispatch(module, store, Jason.decode!(body))
  end

  defp dispatch("/create-log", module, store, payload) do
    metadata =
      payload
      |> Map.take(["format_version", "created_at"])
      |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)

    module.create_log(store, payload["log_id"], metadata)
    |> plain_response(201)
  end

  defp dispatch("/take-lease", module, store, payload) do
    case module.take_lease(store, payload["log_id"]) do
      {:ok, epoch} -> response(200, %{"ok" => true, "lease_epoch" => epoch})
      error -> error_response(error)
    end
  end

  defp dispatch("/read-set", module, store, payload) do
    query = %{
      writers: payload["writers"],
      coordinates: Enum.map(payload["coordinates"], &{&1["writer_id"], &1["writer_seq"]}),
      entry_ids: payload["entry_ids"]
    }

    case module.read_set(store, payload["log_id"], query) do
      {:ok, read_set} -> response(200, %{"ok" => true, "read_set" => encode_read_set(read_set)})
      error -> error_response(error)
    end
  end

  defp dispatch("/commit", module, store, payload) do
    plan = %CommitPlan{
      log_id: payload["log_id"],
      expected_revision: payload["expected_revision"],
      expected_epoch: payload["expected_epoch"],
      insert_entries: Enum.map(payload["insert_entries"], &decode_entry/1),
      put_tips: Enum.map(payload["put_tips"], &decode_tip/1)
    }

    case module.commit(store, plan) do
      {:ok, revision} -> response(200, %{"ok" => true, "revision" => revision})
      error -> error_response(error)
    end
  end

  defp dispatch("/frontier", module, store, payload) do
    case module.frontier(store, payload["log_id"]) do
      {:ok, frontier} -> response(200, %{"ok" => true, "frontier" => encode_frontier(frontier)})
      error -> error_response(error)
    end
  end

  defp dispatch("/read-writer", module, store, payload) do
    opts =
      [after_seq: payload["after_seq"], limit: payload["limit"]]
      |> maybe_put(:through_seq, payload["through_seq"])

    case module.read_writer(store, payload["log_id"], payload["writer_id"], opts) do
      {:ok, page} -> response(200, %{"ok" => true, "page" => encode_writer_page(page)})
      error -> error_response(error)
    end
  end

  defp dispatch("/tail-local", module, store, payload) do
    opts = [after_arrival: payload["after_arrival"], limit: payload["limit"]]

    case module.tail_local(store, payload["log_id"], opts) do
      {:ok, page} -> response(200, %{"ok" => true, "page" => encode_local_page(page)})
      error -> error_response(error)
    end
  end

  defp plain_response(:ok, status), do: response(status, %{"ok" => true})
  defp plain_response(error, _status), do: error_response(error)

  defp error_response({:error, :not_found}), do: error(404, "not_found")
  defp error_response({:error, :stale_revision}), do: error(409, "stale_revision")
  defp error_response({:error, :obsolete_epoch}), do: error(409, "obsolete_epoch")
  defp error_response({:error, :log_mismatch}), do: error(409, "log_mismatch")
  defp error_response({:error, :constraint_violation}), do: error(409, "constraint_violation")
  defp error_response({:error, _reason}), do: error(507, "storage_full")

  defp error(status, code) do
    response(status, %{"ok" => false, "error" => %{"code" => code}})
  end

  defp response(status, body) do
    {:ok,
     %{
       status: status,
       headers: [{"content-type", "application/json"}],
       body: Jason.encode!(body)
     }}
  end

  defp encode_read_set(read_set) do
    %{
      "log_id" => read_set.log_id,
      "format_version" => 1,
      "revision" => read_set.revision,
      "lease_epoch" => read_set.lease_epoch,
      "tips" =>
        Enum.map(read_set.tips, fn {writer_id, tip} ->
          %{"writer_id" => writer_id, "last_seq" => tip.seq, "last_entry_id" => tip.entry_id}
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

  defp encode_frontier(frontier) do
    %{
      "writers" =>
        Enum.map(frontier.writers, fn tip ->
          %{"writer_id" => tip.writer_id, "seq" => tip.seq, "entry_id" => tip.entry_id}
        end)
    }
  end

  defp encode_writer_page(page) do
    %{
      "entries" =>
        Enum.map(page.entries, fn row ->
          %{
            "canonical_bytes" => Base.encode64(row.canonical_bytes),
            "writer_seq" => row.writer_seq
          }
        end),
      "next_after_seq" => page.next_after_seq
    }
  end

  defp encode_local_page(page) do
    %{
      "entries" =>
        Enum.map(page.entries, fn row ->
          %{
            "canonical_bytes" => Base.encode64(row.canonical_bytes),
            "arrival_seq" => row.arrival_seq
          }
        end),
      "next_after_arrival" => page.next_after_arrival
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
    %{writer_id: row["writer_id"], seq: row["last_seq"], entry_id: row["last_entry_id"]}
  end

  defp maybe_put(options, _key, nil), do: options
  defp maybe_put(options, key, value), do: Keyword.put(options, key, value)
end
