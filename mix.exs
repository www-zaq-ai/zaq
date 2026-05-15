defmodule Zaq.MixProject do
  use Mix.Project

  def project do
    [
      app: :zaq,
      version: "0.9.0",
      source_url: "https://github.com/www-zaq-ai/zaq",
      homepage_url: "https://www-zaq-ai.github.io/zaq/",
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      dialyzer: [
        flags: [:unmatched_returns, :error_handling, :underspecs],
        # This will use your ignore file
        ignore_warnings: ".dialyzer_ignore.exs"
      ],
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
        e2e: :test,
        docs: :docs,
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.post": :test,
        "coveralls.html": :test,
        "coveralls.json": :test
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
      {:lazy_html, ">= 0.1.0"},
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
      {:gen_smtp, "~> 1.2"},
      {:req, "~> 0.5"},
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:gettext, "~> 1.0"},
      {:jason, "~> 1.2"},
      {:dns_cluster, "~> 0.2.0"},
      {:bandit, "~> 1.5"},
      {:bcrypt_elixir, "~> 3.0"},
      {:pgvector, "~> 0.3.1"},
      {:oban, "~> 2.20.3"},
      {:fresh, "~> 0.4.4"},
      {:httpoison, "~> 2.3"},
      {:earmark, "~> 1.4.48"},
      {:nimble_csv, "~> 1.2"},
      {:mailroom, "~> 0.7.1"},
      {:lingua, "~> 0.3.6"},
      {:stream_data, "~> 1.3"},
      {:sage, "~> 0.6.3"},

      # Jido Ecosystem
      {:llm_db, "~> 2026.4", runtime: false},
      {:jido_chat, github: "agentjido/jido_chat", branch: "main"},
      {:jido_chat_mattermost, github: "www-zaq-ai/jido_chat_mattermost", branch: "main"},
      {:jido_chat_discord, github: "www-zaq-ai/jido_chat_discord", branch: "main"},
      # {:nostrum, "~> 0.10", only: [:dev, :prod]}
      {:jido_chat_telegram, github: "agentjido/jido_chat_telegram", branch: "main"},
      {:jido, "~> 2.2", override: true},
      {:jido_action, github: "agentjido/jido_action", branch: "main", override: true},
      {:jido_ai, github: "www-zaq-ai/jido_ai", branch: "main", override: true},
      # {:jido_ai, path: "/Users/julien/Documents/Repos/Github/OSS/jido/jido_ai", override: true},
      {:jido_mcp, github: "www-zaq-ai/jido_mcp", branch: "main"},
      {:jido_studio, github: "agentjido/jido_studio"},
      {:req_llm, github: "agentjido/req_llm", branch: "main", override: true},
      # {:jido_connect,
      #  path:
      #    "/Users/julien/Documents/Repos/Github/OSS/jido/connect/jido_connect/apps/jido_connect",
      #  override: true},
      # {:jido_connect_google_drive,
      #  path:
      #    "/Users/julien/Documents/Repos/Github/OSS/jido/connect/jido_connect/apps/jido_connect_google_drive",
      #  override: true},
      {:jido_connect,
       github: "jfayad/jido_connect", branch: "main", sparse: "apps/jido_connect", override: true},
      {:jido_connect_google,
       github: "jfayad/jido_connect",
       branch: "main",
       sparse: "apps/jido_connect_google",
       override: true},
      {:jido_connect_google_drive,
       github: "jfayad/jido_connect",
       branch: "main",
       sparse: "apps/jido_connect_google_drive",
       override: true},

      # Dev/Test
      {:credo, "~> 1.7.13", only: [:dev, :test], runtime: false},
      {:ex_doc, "~> 0.40", only: [:dev, :docs], runtime: false},
      {:ex_dna, "~> 1.4", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.2", only: [:dev, :test], runtime: false},
      {:git_hooks, "~> 0.8", only: :dev, runtime: false},
      {:git_ops, "~> 2.9", only: :dev, runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:doctor, "~> 0.22", only: [:dev], runtime: false},
      {:excoveralls, "~> 0.18.5", only: :test},
      {:mox, "~> 1.2", only: :test}
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
      setup: [
        "deps.get",
        "deps.patch_jido_ai",
        "ecto.setup",
        "assets.setup",
        "assets.build",
        "zaq.python.fetch"
      ],
      "deps.patch_jido_ai": [jido_ai_patch_cmd(), "deps.compile jido_ai --force"],
      "ecto.setup": ["ecto.create", "ecto.migrate"],
      "ecto.reset": ["ecto.drop", "ecto.setup"],
      test: ["deps.patch_jido_ai", "ecto.create --quiet", "ecto.migrate --quiet", "test"],
      e2e: ["cmd npm --prefix test/e2e run test:journeys"],
      "assets.setup": ["tailwind.install --if-missing", "esbuild.install --if-missing"],
      "assets.build": ["compile", "tailwind zaq", "esbuild zaq"],
      "assets.deploy": [
        "tailwind zaq --minify",
        "esbuild zaq --minify",
        "phx.digest"
      ],
      precommit: [
        "deps.patch_jido_ai",
        "compile --warnings-as-errors",
        "deps.unlock --unused",
        "format",
        "credo --strict",
        "hooks.verify",
        "test --stale"
      ],
      q: ["quality"],
      quality: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "docs --warnings-as-errors",
        "credo --strict"
        # "doctor --summary --raise"
        # "dialyzer"
      ],
      coverup: fn args ->
        # call mix coverup [threshold|95] [limit|3]
        {threshold, limit} =
          case args do
            [threshold, limit] -> {threshold, limit}
            [threshold] -> {threshold, "3"}
            _ -> {"95", "3"}
          end

        command = """
        git --no-pager diff --name-only --diff-filter=AM main...HEAD |
        grep '^lib/.*\\.ex$' |
        sort -u |
        while read -r file; do
          jq -r \
            --arg file "$file" \
            --argjson threshold "#{threshold}" '
              .source_files[]
              | select(.name == $file)
              | {
                  file: .name,
                  covered: ([.coverage[] | select(. != null and . > 0)] | length),
                  relevant: ([.coverage[] | select(. != null)] | length),
                  missed: [.coverage | to_entries[] | select(.value == 0) | .key + 1]
                }
              | select(.relevant > 0)
              | .percent = ((.covered * 100 / .relevant))
              | select(.percent < $threshold)
              | "\\(.percent) \\(.file) — \\(.percent | floor)% — missed line numbers: \\(.missed | join(", "))"
            ' cover/excoveralls.json
        done |
        sort -n |
        head -n #{limit} |
        cut -d' ' -f2-
        """

        Mix.shell().cmd(command)
      end
    ]
  end

  defp jido_ai_patch_cmd do
    "cmd sh -c 'cd deps/jido_ai && " <>
      "if grep -Fq \"max_iterations: Zoi.integer() |> Zoi.optional()\" lib/jido_ai/reasoning/react/strategy.ex && " <>
      "grep -Fq \"max_iterations: Map.get(params, :max_iterations)\" lib/jido_ai/reasoning/react/strategy.ex && " <>
      "grep -Fq \"max_iterations: Keyword.get(opts, :max_iterations\" lib/jido_ai/reasoning/react/strategy.ex; " <>
      "then :; else git apply ../../patches/jido_ai_max_iterations.patch; fi'"
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      groups_for_modules: [
        Channels: [~r/^Zaq\.Channels(\.|$)/],
        Agent: [~r/^Zaq\.Agent(\.|$)/],
        Engine: [~r/^Zaq\.Engine(\.|$)/],
        BackOffice: [
          ~r/^Zaq\.Bo(\.|$)/,
          ~r/^ZaqWeb\.Components(\.|$)/,
          ~r/^ZaqWeb\.Live\.BO(\.|$)/
        ],
        Ingestion: [~r/^Zaq\.Ingestion(\.|$)/],
        System: [~r/^Zaq\.System(\.|$)/],
        Accounts: [~r/^Zaq\.Accounts(\.|$)/],
        License: [~r/^Zaq\.License(\.|$)/]
      ]
    ]
  end
end
