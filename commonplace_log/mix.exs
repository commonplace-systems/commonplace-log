defmodule CommonplaceLog.MixProject do
  use Mix.Project

  def project do
    [
      app: :commonplace_log,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger, :crypto]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:exqlite, "~> 0.27"},
      {:stream_data, "~> 1.1", only: [:test, :dev]}
    ]
  end
end
