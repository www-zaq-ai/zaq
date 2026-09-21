defmodule Mix.Tasks.Db.ExtensionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Ecto.Adapters.Postgres
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox
  alias Mix.Tasks.Db.Extensions
  alias Zaq.Repo
  alias Zaq.Repo.ExtensionChecks
  alias Zaq.Test.DbExtensionsRepo
  alias Zaq.Test.DbExtensionsSystem

  setup do
    previous_task_config = Application.get_env(:zaq, Extensions)
    previous_repo_config = Application.get_env(:zaq, DbExtensionsRepo)
    Mix.Task.reenable("db.extensions")

    Sandbox.mode(Repo, :auto)

    on_exit(fn ->
      restore_env(Extensions, previous_task_config)
      restore_env(DbExtensionsRepo, previous_repo_config)
      Process.delete(:db_extensions_executable)
      Process.delete(:db_extensions_command)
      Process.delete(:db_extensions_command_result)
      Sandbox.mode(Repo, :manual)
    end)

    :ok
  end

  test "idempotently prepares every extension available to the configured repo" do
    output = capture_io(fn -> Extensions.run(["--repo", inspect(Repo)]) end)

    assert :ok = ExtensionChecks.require!(Repo, :vector)

    if pg_search_available?() do
      assert :ok = ExtensionChecks.require!(Repo, :pg_search)
      assert {:ok, _result} = SQL.query(Repo, "SELECT 1 FROM paradedb.version_info()", [])
      assert output =~ "vector and pg_search"
    else
      assert output =~ "vector; pg_search is unavailable"
    end

    assert capture_io(fn -> Extensions.run(["--repo", inspect(Repo)]) end) =~
             "Database extensions ready"
  end

  test "installs vector in a fresh database before migrations" do
    database = temporary_database_name()

    config =
      Repo.config()
      |> Keyword.put(:database, database)
      |> Keyword.put(:pool, DBConnection.ConnectionPool)
      |> Keyword.put(:pool_size, 1)

    Application.put_env(:zaq, DbExtensionsRepo, config)
    assert :ok = Postgres.storage_up(config)

    on_exit(fn ->
      Postgres.storage_down(config)
    end)

    assert capture_io(fn ->
             Extensions.run(["--repo", inspect(DbExtensionsRepo), "--quiet"])
           end) == ""

    assert {:ok, :ok, _started_apps} =
             Ecto.Migrator.with_repo(
               DbExtensionsRepo,
               fn repo ->
                 assert :ok = ExtensionChecks.require!(repo, :vector)

                 assert %{rows: [[nil]]} =
                          SQL.query!(repo, "SELECT to_regclass('public.schema_migrations')", [])

                 :ok
               end,
               mode: :temporary
             )
  end

  test "supports quiet setup aliases" do
    assert capture_io(fn -> Extensions.run(["--repo", inspect(Repo), "--quiet"]) end) == ""
    assert :ok = ExtensionChecks.require!(Repo, :vector)
  end

  test "prepares the application's configured repos by default" do
    assert capture_io(fn -> Extensions.run(["--quiet"]) end) == ""
    assert :ok = ExtensionChecks.require!(Repo, :vector)
  end

  test "rejects positional arguments and unknown options" do
    assert_raise Mix.Error, ~r/Usage: mix db.extensions/, fn ->
      Extensions.run(["unexpected"])
    end

    assert_raise Mix.Error, ~r/Usage: mix db.extensions/, fn ->
      Extensions.run(["--unknown"])
    end
  end

  test "runs the shared script with configured connection fields" do
    use_fake_system()

    Application.put_env(:zaq, DbExtensionsRepo,
      hostname: "db.local",
      port: 5544,
      username: "developer",
      password: "secret",
      database: "zaq_branch",
      ssl: true
    )

    assert capture_io(fn ->
             Extensions.run(["--repo", inspect(DbExtensionsRepo), "--quiet"])
           end) == ""

    assert {"/fake/bin/psql", ["-X", "--quiet", "--file", script], opts} =
             Process.get(:db_extensions_command)

    assert String.ends_with?(script, "scripts/setup_development_extensions.sql")

    assert opts[:env] == [
             {"PGHOST", "db.local"},
             {"PGPORT", "5544"},
             {"PGUSER", "developer"},
             {"PGPASSWORD", "secret"},
             {"PGDATABASE", "zaq_branch"},
             {"PGSSLMODE", "require"}
           ]

    assert opts[:stderr_to_stdout]
  end

  test "keeps URL-derived credentials out of command arguments" do
    use_fake_system()
    Application.put_env(:zaq, DbExtensionsRepo, url: "ecto://developer:secret@db.local/zaq")

    Extensions.run(["--repo", inspect(DbExtensionsRepo), "--quiet"])

    {_executable, args, opts} = Process.get(:db_extensions_command)
    refute Enum.any?(args, &String.contains?(&1, "secret"))

    assert opts[:env] == [
             {"PGHOST", "db.local"},
             {"PGPORT", "5432"},
             {"PGUSER", "developer"},
             {"PGPASSWORD", "secret"},
             {"PGDATABASE", "zaq"},
             {"PGSSLMODE", "disable"}
           ]
  end

  test "reports missing psql and script failures as Mix errors" do
    use_fake_system()
    Application.put_env(:zaq, DbExtensionsRepo, database: "zaq_branch")
    Process.put(:db_extensions_executable, nil)

    assert_raise Mix.Error, "psql not found", fn ->
      Extensions.run(["--repo", inspect(DbExtensionsRepo), "--quiet"])
    end

    Process.put(:db_extensions_executable, "/fake/bin/psql")
    Process.put(:db_extensions_command_result, {"permission denied", 1})

    assert_raise Mix.Error, ~r/Database extension setup failed.*permission denied/s, fn ->
      Extensions.run(["--repo", inspect(DbExtensionsRepo), "--quiet"])
    end
  end

  defp pg_search_available? do
    %{rows: [[available?]]} =
      SQL.query!(
        Repo,
        "SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_search')",
        []
      )

    available?
  end

  defp temporary_database_name do
    suffix = System.unique_integer([:positive, :monotonic])
    "zaq_extensions_test_#{suffix}"
  end

  defp use_fake_system do
    Application.put_env(:zaq, Extensions, system: DbExtensionsSystem)
  end

  defp restore_env(key, nil), do: Application.delete_env(:zaq, key)
  defp restore_env(key, value), do: Application.put_env(:zaq, key, value)
end
