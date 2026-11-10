defmodule AshI3x.MixProject do
  use Mix.Project

  @version "0.1.0"

  def project do
    [
      app: :ash_i3x,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      consolidate_protocols: Mix.env() != :test,
      deps: deps(),
      description: "Serve Ash resources over the i3X industrial information API",
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {AshI3x.Application, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:ash, "~> 3.0"},
      {:plug, "~> 1.14"},
      {:jason, "~> 1.4"},
      {:simple_sat, "~> 0.1", only: :test},
      {:bandit, "~> 1.0", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end
