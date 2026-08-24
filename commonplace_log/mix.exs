defmodule CommonplaceLog.MixProject do
  use Mix.Project

  def project do
    [
      app: :commonplace_log,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: "https://github.com/commonplace-systems/commonplace-log"
    ]
  end

  defp description do
    "An append-only log made of independent, gapless per-writer sequences: " <>
      "replicas merge by prefix, no consensus, and writer forks are reported and refused."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => "https://github.com/commonplace-systems/commonplace-log"}
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {CommonplaceLog.Application, []},
      extra_applications: [:logger, :crypto, :ssl, :inets]
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
