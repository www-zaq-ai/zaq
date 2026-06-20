defmodule Mix.Tasks.Db.Copy do
  use Mix.Task

  @shortdoc "Copy data from one DB to another using current Repo config"

  @moduledoc """
  Usage:

      mix db.copy source_db target_db
      mix db.copy source_db target_db --clean
  """

  @impl true
  def run(args) do
    Mix.Task.run("app.start")

    {opts, db_names, _invalid} =
      OptionParser.parse(args,
        strict: [clean: :boolean, repo: :string],
        aliases: [r: :repo]
      )

    case db_names do
      [source_db, target_db] ->
        repo = repo_module(opts[:repo])
        config = repo.config()

        source_url = database_url(config, source_db)
        target_url = database_url(config, target_db)

        copy_db(source_url, target_url, opts)

      _ ->
        Mix.raise("""
        Usage:

            mix db.copy source_db target_db
            mix db.copy source_db target_db --clean
            mix db.copy source_db target_db --repo MyApp.Repo
        """)
    end
  end

  defp repo_module(nil) do
    Application.fetch_env!(Mix.Project.config()[:app], :ecto_repos)
    |> List.first()
  end

  defp repo_module(repo) when is_binary(repo) do
    Module.concat([repo])
  end

  defp database_url(config, database_name) do
    config =
      config
      |> Keyword.put(:database, database_name)

    username = config[:username]
    password = config[:password]
    hostname = config[:hostname] || "localhost"
    port = config[:port] || 5432
    database = config[:database]

    URI.to_string(%URI{
      scheme: "postgres",
      userinfo: userinfo(username, password),
      host: hostname,
      port: port,
      path: "/" <> database
    })
  end

  defp userinfo(nil, nil), do: nil
  defp userinfo(username, nil), do: URI.encode_www_form(to_string(username))

  defp userinfo(username, password) do
    URI.encode_www_form(to_string(username)) <>
      ":" <>
      URI.encode_www_form(to_string(password))
  end

  defp copy_db(source_url, target_url, opts) do
    restore_args =
      [
        "--dbname=#{target_url}",
        "--no-owner",
        "--no-acl"
      ]

    restore_args =
      if opts[:clean] do
        ["--clean", "--if-exists" | restore_args]
      else
        restore_args
      end

    dump = System.find_executable("pg_dump") || Mix.raise("pg_dump not found")
    restore = System.find_executable("pg_restore") || Mix.raise("pg_restore not found")

    dump_cmd = [dump, "--format=custom", "--no-owner", "--no-acl", source_url]
    restore_cmd = [restore | restore_args]

    Mix.shell().info("Copying #{redacted(source_url)} -> #{redacted(target_url)}")

    {_, status} =
      System.cmd(
        "sh",
        [
          "-c",
          Enum.map_join(dump_cmd, " ", &shell_escape/1) <>
            " | " <>
            Enum.map_join(restore_cmd, " ", &shell_escape/1)
        ],
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0 do
      Mix.raise("Database copy failed")
    end

    Mix.shell().info("Done.")
  end

  defp shell_escape(arg), do: "'" <> String.replace(arg, "'", "'\"'\"'") <> "'"

  defp redacted(url) do
    URI.parse(url)
    |> Map.put(:userinfo, "*****")
    |> URI.to_string()
  end
end
