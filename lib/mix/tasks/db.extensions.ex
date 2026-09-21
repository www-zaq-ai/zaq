defmodule Mix.Tasks.Db.Extensions do
  use Mix.Task

  @shortdoc "Install database extensions required by local development"
  @requirements ["app.config"]

  @moduledoc """
  Runs ZAQ's shared extension setup SQL using each configured Repo connection.

  This task is intended for local developer setup, where the configured database
  user can create extensions. It installs the required `vector` extension and
  installs `pg_search` when the server provides it. The same extension SQL fragments
  are used by managed database bootstrap. Existing extensions are left unchanged.

      mix db.extensions
      mix db.extensions --repo Zaq.Repo --quiet
  """

  @switches [repo: :keep, quiet: :boolean]

  @impl true
  def run(args) do
    {opts, positional, invalid} = OptionParser.parse(args, strict: @switches)

    if positional != [] or invalid != [] do
      Mix.raise("Usage: mix db.extensions [--repo MyApp.Repo] [--quiet]")
    end

    opts
    |> repos()
    |> Enum.each(&prepare_repo(&1, opts[:quiet]))
  end

  defp repos(opts) do
    case Keyword.get_values(opts, :repo) do
      [] -> Application.fetch_env!(Mix.Project.config()[:app], :ecto_repos)
      names -> Enum.map(names, &Module.concat([&1]))
    end
  end

  defp prepare_repo(repo, quiet?) do
    system = system_module()
    psql = system.find_executable("psql") || Mix.raise("psql not found")

    {output, status} =
      system.cmd(
        psql,
        ["-X", "--quiet", "--file", extension_script()],
        env: connection_env(repo.config()),
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("Database extension setup failed for #{inspect(repo)}:\n#{output}")
    end

    unless quiet? do
      output
      |> String.trim()
      |> Mix.shell().info()
    end
  end

  defp extension_script do
    Mix.Project.project_file()
    |> Path.dirname()
    |> Path.join("scripts/setup_development_extensions.sql")
    |> Path.expand()
  end

  defp connection_env(config) do
    [
      {"PGHOST", config[:hostname] || "localhost"},
      {"PGPORT", to_string(config[:port] || 5432)},
      {"PGUSER", optional_string(config[:username])},
      {"PGPASSWORD", optional_string(config[:password])},
      {"PGDATABASE", config[:database]},
      {"PGSSLMODE", ssl_mode(config[:ssl])}
    ]
  end

  defp optional_string(nil), do: nil
  defp optional_string(value), do: to_string(value)

  defp ssl_mode(ssl) when ssl in [nil, false], do: "disable"
  defp ssl_mode(_), do: "require"

  defp system_module do
    :zaq
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:system, System)
  end
end
