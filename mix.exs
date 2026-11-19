defmodule Sap.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/rothy-s/sap.ex"

  def project do
    [
      app: :sap,
      version: @version,
      elixir: "~> 1.20",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      docs: docs(),
      dialyzer: dialyzer(),
      test_coverage: test_coverage(),
      usage_rules: usage_rules(),
      package: package(),
      deps: deps(),
      name: "Sap",
      description: "Elixir client for SAP S/4HANA OData services",
      source_url: @source_url
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "Sap",
      source_url: @source_url,
      source_ref: "main",
      extras: ["README.md"],
      groups_for_modules: [
        Core: [Sap, Sap.Client, Sap.Client.Config, Sap.Operation, Sap.Error, Sap.Error.Detail],
        Batches: ~r"Sap\.Batch",
        Customers: ~r"Sap\.Customers",
        "Sales orders": ~r"Sap\.SalesOrders",
        HTTP: ~r"Sap\.HTTP",
        OData: ~r"Sap\.Odata"
      ]
    ]
  end

  defp dialyzer do
    [
      plt_file: {:no_warn, "priv/plts/project.plt"},
      plt_add_apps: [:ex_unit]
    ]
  end

  # `mix test --cover` fails below this. Test support code is not part of the library.
  defp test_coverage do
    [
      summary: [threshold: 90],
      ignore_modules: [Sap.ApiCase]
    ]
  end

  # Keeps the dependency rules section of AGENTS.md in sync: `mix usage_rules.sync`.
  defp usage_rules do
    [
      file: "AGENTS.md",
      usage_rules: [{~r/.*/, link: :markdown}]
    ]
  end

  # `usage-rules.md` and `usage-rules/` ship with the package so host apps' agents can use them.
  defp package do
    [
      files: ~w(lib usage-rules usage-rules.md mix.exs README.md .formatter.exs),
      links: %{"GitHub" => @source_url}
    ]
  end

  defp deps do
    [
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:decimal, "~> 2.0 or ~> 3.0"},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:plug, "~> 1.16", only: :test},
      {:req, "~> 0.7.4"},
      {:usage_rules, "~> 1.3", only: [:dev]}
    ]
  end
end
