defmodule Commonplace.Log.RealmNode do
  @moduledoc "HTTP surface for one BEAM realm-node incarnation."

  use Plug.Router

  alias Commonplace.Log.Engine
  alias Commonplace.Log.Persistence.{CloudflareSidecar, LocalSQLite}
  alias Commonplace.Log.RealmNode.Incarnation

  plug(:match)
  plug(:dispatch)

  get "/ping" do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, "ok")
  end

  get "/v1/incarnation" do
    json(conn, 200, Map.put(Incarnation.current(), :ok, true))
  end

  post "/v1/logs/:log_id/create" do
    with_store(conn, log_id, fn conn, persistence, store ->
      case persistence.frontier(store, log_id) do
        {:ok, _frontier} -> error(conn, 409, "already_exists", %{})
        {:error, :not_found} -> create_result(conn, persistence.create_log(store, log_id, %{}))
        other -> result(conn, other)
      end
    end)
  end

  post "/v1/logs/:log_id/append" do
    with {:ok, body} <- decode_object(conn),
         {:ok, writer_id} <- required_string(body, "writer_id"),
         {:ok, entry_body} <- required_object(body, "body"),
         {:ok, created_at} <- created_at(body) do
      with_store(conn, log_id, fn conn, persistence, store ->
        case Engine.append(persistence, store, log_id, writer_id, entry_body, created_at) do
          {:ok, %{revision: revision} = engine_result} ->
            entry = Map.drop(engine_result, [:revision])
            json(conn, 200, %{ok: true, entry: entry, revision: revision})

          other ->
            result(conn, other)
        end
      end)
    else
      {:error, reason} -> error(conn, 400, "invalid_entry", %{reason: reason})
    end
  end

  post "/v1/logs/:log_id/merge" do
    with {:ok, body} <- decode_object(conn),
         {:ok, entries} <- required_entry_maps(body) do
      raw_entries = Enum.map(entries, &Jason.encode!/1)

      with_store(conn, log_id, fn conn, persistence, store ->
        case Engine.merge(persistence, store, log_id, raw_entries) do
          {:ok, engine_result} -> json(conn, 200, Map.put(engine_result, :ok, true))
          other -> result(conn, other)
        end
      end)
    else
      {:error, reason} -> error(conn, 400, "invalid_entry", %{reason: reason})
    end
  end

  get "/v1/logs/:log_id/frontier" do
    with_store(conn, log_id, fn conn, persistence, store ->
      case persistence.frontier(store, log_id) do
        {:ok, frontier} -> json(conn, 200, %{ok: true, frontier: frontier})
        other -> result(conn, other)
      end
    end)
  end

  match _ do
    error(conn, 404, "not_found", %{})
  end

  defp with_store(conn, log_id, fun) do
    case persistence_config() do
      {LocalSQLite, options} when is_list(options) ->
        data_dir = Keyword.fetch!(options, :data_dir)

        case LocalSQLite.open(data_dir, log_id) do
          {:ok, store} ->
            try do
              fun.(conn, LocalSQLite, store)
            after
              LocalSQLite.close(store)
            end

          other ->
            result(conn, other)
        end

      {CloudflareSidecar, options} when is_list(options) ->
        {base_url, adapter_options} = Keyword.pop!(options, :base_url)
        fun.(conn, CloudflareSidecar, CloudflareSidecar.new(base_url, adapter_options))

      {persistence, store} when is_atom(persistence) ->
        fun.(conn, persistence, store)

      _invalid ->
        error(conn, 502, "configuration_error", %{reason: "invalid persistence configuration"})
    end
  end

  defp persistence_config do
    Application.get_env(:commonplace_log, __MODULE__, [])
    |> Keyword.get_lazy(:persistence, fn ->
      {CloudflareSidecar,
       base_url: System.get_env("COMMONPLACE_SIDECAR_URL") || "http://storage.internal"}
    end)
  end

  defp decode_object(conn) do
    with {:ok, body, _conn} <- read_entire_body(conn),
         {:ok, %{} = value} <- Jason.decode(body) do
      {:ok, value}
    else
      {:ok, _value} -> {:error, "request-body-not-object"}
      {:error, %Jason.DecodeError{}} -> {:error, "malformed-json"}
      {:error, _reason} -> {:error, "request-body-read-error"}
    end
  end

  defp read_entire_body(conn, accumulated \\ "") do
    case Plug.Conn.read_body(conn) do
      {:ok, body, conn} -> {:ok, accumulated <> body, conn}
      {:more, body, conn} -> read_entire_body(conn, accumulated <> body)
      {:error, reason} -> {:error, reason}
    end
  end

  defp required_string(body, key) do
    case Map.get(body, key) do
      value when is_binary(value) -> {:ok, value}
      _ -> {:error, "#{key}-not-string"}
    end
  end

  defp required_object(body, key) do
    case Map.get(body, key) do
      %{} = value -> {:ok, value}
      _ -> {:error, "#{key}-not-object"}
    end
  end

  defp required_entry_maps(%{"entries" => entries}) when is_list(entries) do
    if Enum.all?(entries, &is_map/1),
      do: {:ok, entries},
      else: {:error, "entries-contain-non-object"}
  end

  defp required_entry_maps(_body), do: {:error, "entries-not-list"}

  defp created_at(%{"created_at" => value}) when is_binary(value), do: {:ok, value}
  defp created_at(%{"created_at" => _value}), do: {:error, "created_at-not-string"}
  defp created_at(_body), do: {:ok, DateTime.utc_now()}

  defp create_result(conn, :ok), do: json(conn, 201, %{ok: true})

  defp create_result(conn, {:error, reason})
       when reason in [:already_exists, :constraint_violation],
       do: error(conn, 409, "already_exists", %{})

  defp create_result(conn, other), do: result(conn, other)

  defp result(conn, result, success_status \\ 200)
  defp result(conn, :ok, success_status), do: json(conn, success_status, %{ok: true})

  defp result(conn, {:ok, value}, success_status),
    do: json(conn, success_status, %{ok: true, result: value})

  defp result(conn, {:error, code, reason}, _success_status),
    do: mapped_error(conn, code, %{reason: reason})

  defp result(conn, {:error, {code, details}}, _success_status),
    do: mapped_error(conn, code, details)

  defp result(conn, {:error, code}, _success_status), do: mapped_error(conn, code, %{})
  defp result(conn, other, _success_status), do: gateway_error(conn, other)

  defp mapped_error(conn, code, details) do
    normalized = code |> to_string() |> String.trim_leading(":")

    status =
      case normalized do
        "not_found" ->
          404

        "log_not_found" ->
          404

        code when code in ["writer_fork", "writer_gap", "entry_id_collision", "stale_revision"] ->
          409

        code when code in ["invalid_entry", "invalid_json", "entry_too_large", "log_mismatch"] ->
          400

        "unauthorized" ->
          502

        _other ->
          502
      end

    response_code = if normalized == "not_found", do: "log_not_found", else: normalized

    if normalized == "unauthorized" do
      error(conn, 502, response_code, %{reason: "upstream unauthorized"})
    else
      respond_to_mapped_error(conn, status, response_code, code, details)
    end
  end

  defp respond_to_mapped_error(conn, 502, response_code, code, details) do
    gateway_error(conn, {code, details}, response_code)
  end

  defp respond_to_mapped_error(conn, status, response_code, _code, details),
    do: error(conn, status, response_code, json_safe(details))

  defp gateway_error(conn, reason, code \\ "upstream_error") do
    error(conn, 502, code, %{reason: inspect(reason, limit: 20, printable_limit: 512)})
  end

  defp json_safe(value) when is_map(value),
    do: Map.new(value, fn {key, item} -> {key, json_safe(item)} end)

  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)
  defp json_safe(value) when is_tuple(value), do: inspect(value, limit: 20, printable_limit: 512)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value), do: value

  defp error(conn, status, code, details) do
    json(conn, status, %{ok: false, error: %{code: code, details: details}})
  end

  defp json(conn, status, value) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(value))
  end
end
