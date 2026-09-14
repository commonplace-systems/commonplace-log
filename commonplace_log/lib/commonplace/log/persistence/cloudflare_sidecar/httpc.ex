defmodule Commonplace.Log.Persistence.CloudflareSidecar.Httpc do
  @moduledoc "OTP `:httpc` implementation of the sidecar transport boundary."

  @behaviour Commonplace.Log.Persistence.CloudflareSidecar.Transport

  # :httpc defaults both timeouts to infinity, so a hung sidecar would wedge the
  # calling process forever. Connecting to the sidecar should take at most
  # seconds even across a container boundary; the whole request must still cover
  # a multi-MiB commit body (entries are up to 1 MiB and batches exist) plus
  # sidecar processing, so it gets a minute.
  @default_connect_timeout 5_000
  @default_request_timeout 60_000

  @doc "Fills in finite `timeout`/`connect_timeout` defaults; caller-supplied values win."
  def with_default_timeouts(options) when is_list(options) do
    options
    |> Keyword.put_new(:timeout, @default_request_timeout)
    |> Keyword.put_new(:connect_timeout, @default_connect_timeout)
  end

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

      case :httpc.request(:post, request, with_default_timeouts(options), body_format: :binary) do
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
