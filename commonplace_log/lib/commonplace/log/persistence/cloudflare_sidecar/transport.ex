defmodule Commonplace.Log.Persistence.CloudflareSidecar.Transport do
  @moduledoc "Transport boundary for sidecar HTTP requests."

  @type response :: %{
          required(:status) => non_neg_integer(),
          required(:headers) => [{String.t(), String.t()}],
          required(:body) => binary()
        }

  @callback request(
              method :: :post,
              url :: String.t(),
              headers :: [{String.t(), String.t()}],
              body :: binary(),
              options :: term()
            ) :: {:ok, response()} | {:error, term()}
end
