defmodule Zaq.MixProject do
  use Mix.Project

  def project do
    [
      app: :zaq,
      version: "0.2.0",
      source_url: "https://github.com/www-zaq-ai/zaq",
      homepage_url: "https://www-zaq-ai.github.io/zaq/",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      compilers: [:phoenix_live_view] ++ Mix.compilers(),
      listeners: [Phoenix.CodeReloader],
      test_coverage: [tool: ExCoveralls],
      docs: docs()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Zaq.Application, []},
      extra_applications: [:logger, :runtime_tools, :crypto]
    ]
  end

  def cli do
    [
      preferred_envs: [
        precommit: :test,
        docs: :docs,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test
      ]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(:docs), do: ["lib"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix, "~> 1.8.3"},
      {:phoenix_ecto, "~> 4.5"},
      {:ecto_sql, "~> 3.13"},
      {:postgrex, ">= 0.0.0"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_reload, "~> 1.2", only: :dev},
      {:phoenix_live_view, "~> 1.1.0"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_live_dashboard, "~> 0.8.3"},
      {:esbuild, "~> 0.10", runtime: Mix.env() == :dev},
      {:tailwind, "~> 0.3", runtime: Mix.env() == :dev},
      {:heroicons,
       github: "tailwindlabs/heroicons",
       tag: "v2.2.0",
       sparse: "optimized",
       app: false,
       compile: false,
       depth: 1},
      {:swoosh, "~> 1.16"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:bcrypt_elixir, "~> 3.0"},
      {:credo, "~> 1.7.13", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :docs], runtime: false},
      {:excoveralls, "~> 0.18.5", only: :test},
      {:pgvector, "~> 0.3.1"},
      {:langchain, github: "Geeks-Solutions/langchain", branch: "main"},
      {:mox, "~> 1.2", only: :test},
      {:oban, "~> 2.20.3"},
      {:file_system, "~> 1.1"},
      {:fresh, "~> 0.4.4"},
      {:httpoison, "~> 2.3"},
      {:earmark, "~> 1.4.48"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  # For example, to install project dependencies and perform other setup tasks, run:
  #
  #     $ mix setup
  #
  # See the documentation for `Mix` for more info on aliases.
  defp aliases do
    [
      setup: ["deps.get", "ecto.setup", "assets.setup", "assets.build"],
      "ecto.setup": ["ecto.create", "ecto.migrate", "run priv/repo/seeds.exs"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind zaq", "esbuild zaq"],
      "assets.deploy": [
        "tailwind zaq --minify",
        "esbuild zaq --minify",
        "phx.digest"
      ],
      precommit: [
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "test"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"] ++ (Path.wildcard("docs/*.md") |> Enum.sort())
    ]
  end
end
