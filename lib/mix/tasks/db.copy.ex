defmodule Mix.Tasks.Db.Copy do
  use Mix.Task

  @shortdoc "Copy another Postgres DB into the current Repo DB"

  @moduledoc """
  Full copy of a source DB into the current DB (defined by branch name in dev environment)

  This command will migrate db schema and data into an empty DB to make it ready for work on an isolated branch

  If no source DB is provided, it will use the default `zaq_main` one

  ## Usage

    mix db.copy
  """

  @impl true
  def run(args) do
    {opts, db_names, _} =
      OptionParser.parse(args,
        strict: [
          repo: :string,
          force: :boolean
        ],
        aliases: [r: :repo]
      )

    case db_names do
      [source_db] ->
        repo = repo_module(opts[:repo])
        config = repo.config()

        source_url = database_url(config, source_db)
        target_url = database_url(config)

        if same_database?(source_url, target_url) do
          Mix.raise("Source and target databases are the same")
        end

        unless opts[:force] do
          ensure_target_empty!(target_url)
        end

        copy_full_db!(source_url, target_url)

      _ ->
        Mix.raise("""
        Usage:

            mix db.copy source_db
            mix db.copy source_db --repo MyApp.Repo
            mix db.copy source_db --force
        """)
    end
  end

  defp repo_module(nil) do
    Application.fetch_env!(Mix.Project.config()[:app], :ecto_repos)
    |> List.first()
  end

  defp repo_module(repo), do: Module.concat([repo])

  defp database_url(config) do
    case config[:url] do
      nil -> database_url_from_parts(config)
      url -> url
    end
  end

  defp database_url(config, database_name) do
    case config[:url] do
      nil ->
        config
        |> Keyword.put(:database, database_name)
        |> database_url_from_parts()

      url ->
        url
        |> URI.parse()
        |> Map.put(:path, "/" <> database_name)
        |> URI.to_string()
    end
  end

  defp database_url_from_parts(config) do
    URI.to_string(%URI{
      scheme: "postgres",
      userinfo: userinfo(config[:username], config[:password]),
      host: config[:hostname] || "localhost",
      port: config[:port] || 5432,
      path: "/" <> config[:database]
    })
  end

  defp userinfo(nil, nil), do: nil
  defp userinfo(username, nil), do: URI.encode_www_form(to_string(username))

  defp userinfo(username, password) do
    URI.encode_www_form(to_string(username)) <>
      ":" <>
      URI.encode_www_form(to_string(password))
  end

  defp ensure_target_empty!(target_url) do
    psql = System.find_executable("psql") || Mix.raise("psql not found")

    sql = """
    SELECT count(*)
    FROM pg_tables
    WHERE schemaname = 'public';
    """

    {output, status} =
      System.cmd(psql, [target_url, "-t", "-A", "-v", "ON_ERROR_STOP=1", "-c", sql],
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("Could not inspect target database:\n#{output}")
    end

    table_count =
      output
      |> String.trim()
      |> String.to_integer()

    if table_count > 0 do
      Mix.raise("""
      Target database is not empty.

      This task is intended to run after:

          mix ecto.create

      but before:

          mix ecto.migrate

      If you really want to restore into this database anyway, pass --force.
      """)
    end
  end

  defp copy_full_db!(source_url, target_url) do
    pg_dump = System.find_executable("pg_dump") || Mix.raise("pg_dump not found")
    pg_restore = System.find_executable("pg_restore") || Mix.raise("pg_restore not found")

    dump_path =
      Path.join(System.tmp_dir!(), "db-copy-#{System.unique_integer([:positive])}.dump")

    Mix.shell().info("""
    Copying full database:

      source: #{redacted(source_url)}
      target: #{redacted(target_url)}
    """)

    try do
      {dump_output, dump_status} =
        System.cmd(
          pg_dump,
          [
            "--format=custom",
            "--no-owner",
            "--no-acl",
            "--file",
            dump_path,
            source_url
          ],
          stderr_to_stdout: true
        )

      if dump_status != 0 do
        Mix.raise("pg_dump failed:\n#{dump_output}")
      end

      {restore_output, restore_status} =
        System.cmd(
          pg_restore,
          [
            "--exit-on-error",
            "--single-transaction",
            "--no-owner",
            "--no-acl",
            "--dbname",
            target_url,
            dump_path
          ],
          into: IO.stream(:stdio, :line),
          stderr_to_stdout: true
        )

      if restore_status != 0 do
        Mix.raise("pg_restore failed:\n#{restore_output}")
      end

      Mix.shell().info("Database copied successfully.")
    after
      File.rm(dump_path)
    end
  end

  defp same_database?(source_url, target_url) do
    normalize_db_url(source_url) == normalize_db_url(target_url)
  end

  defp normalize_db_url(url) do
    uri = URI.parse(url)

    {
      uri.scheme,
      uri.host,
      uri.port || 5432,
      uri.path
    }
  end

  defp redacted(url) do
    url
    |> URI.parse()
    |> Map.put(:userinfo, "*****")
    |> URI.to_string()
  end
end
