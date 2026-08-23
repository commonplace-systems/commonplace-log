defmodule Commonplace.Log.Persistence.CloudflareSidecar.Httpc do
  @moduledoc "OTP `:httpc` implementation of the sidecar transport boundary."

  @behaviour Commonplace.Log.Persistence.CloudflareSidecar.Transport

  @impl true
  def request(:post, url, headers, body, options)
      when is_binary(url) and is_list(headers) and is_binary(body) and is_list(options) do
    with {:ok, _ssl_started} <- Application.ensure_all_started(:ssl),
         {:ok, _inets_started} <- Application.ensure_all_started(:inets) do
      http_headers =
        headers
        |> Enum.reject(fn {name, _value} -> String.downcase(name) == "content-type" end)
        |> Enum.map(fn {name, value} -> {String.to_charlist(name), String.to_charlist(value)} end)

      request = {
        String.to_charlist(url),
        http_headers,
        ~c"application/json",
        body
      }

      case :httpc.request(:post, request, options, body_format: :binary) do
        {:ok, {{_http_version, status, _reason_phrase}, response_headers, response_body}} ->
          {:ok,
           %{
             status: status,
             headers:
               Enum.map(response_headers, fn {name, value} ->
                 {List.to_string(name), List.to_string(value)}
               end),
             body: response_body
           }}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end
end
