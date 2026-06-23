defmodule Mix.Tasks.Db.CopyTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias Mix.Tasks.Db.Copy

  defmodule RepoWithoutUrl do
    def config do
      [
        username: "db user",
        password: "db pass",
        hostname: "db.local",
        port: 5544,
        database: "target_db"
      ]
    end
  end

  defmodule RepoWithUrl do
    def config do
      [url: "postgres://db%20user:db%20pass@db.local:5544/target_db"]
    end
  end

  defmodule RepoWithoutPassword do
    def config do
      [username: "db user", hostname: "db.local", database: "target_db"]
    end
  end

  defmodule RepoWithoutCredentials do
    def config do
      [database: "target_db"]
    end
  end

  defmodule FakeSystem do
    def find_executable(name), do: "/fake/bin/#{name}"

    def cmd("/fake/bin/psql", _args, _opts), do: next_cmd()
    def cmd("/fake/bin/pg_dump", _args, _opts), do: next_cmd()
    def cmd("/fake/bin/pg_restore", _args, _opts), do: next_cmd()

    defp next_cmd do
      case Process.get(:db_copy_cmd_results, []) do
        [result | rest] ->
          Process.put(:db_copy_cmd_results, rest)
          result

        [] ->
          {"", 0}
      end
    end
  end

  defmodule MissingPsqlSystem do
    def find_executable("psql"), do: nil
  end

  defmodule MissingPgRestoreSystem do
    def find_executable("pg_dump"), do: "/fake/bin/pg_dump"
    def find_executable("pg_restore"), do: nil
  end

  setup do
    previous = Application.get_env(:zaq, Copy)
    Application.put_env(:zaq, Copy, system: FakeSystem)

    on_exit(fn ->
      Process.delete(:db_copy_cmd_results)

      if previous do
        Application.put_env(:zaq, Copy, previous)
      else
        Application.delete_env(:zaq, Copy)
      end
    end)
  end

  test "raises usage when source database is missing" do
    assert_raise Mix.Error, ~r/Usage:/, fn ->
      Copy.run([])
    end
  end

  test "raises when source and target databases resolve to the same URL" do
    assert_raise Mix.Error, "Source and target databases are the same", fn ->
      Copy.run(["target_db", "--repo", inspect(RepoWithoutUrl)])
    end
  end

  test "inspects an empty target and copies from config parts" do
    Process.put(:db_copy_cmd_results, [{"0\n", 0}, {"dumped", 0}, {"restored", 0}])

    output =
      capture_io(fn ->
        Copy.run(["source_db", "--repo", inspect(RepoWithoutUrl)])
      end)

    assert output =~ "Copying full database:"
    assert output =~ "source: postgres://*****@db.local:5544/source_db"
    assert output =~ "target: postgres://*****@db.local:5544/target_db"
    assert output =~ "Database copied successfully."
  end

  test "rewrites database name in configured URL and skips empty-target check with force" do
    Process.put(:db_copy_cmd_results, [{"dumped", 0}, {"restored", 0}])

    output =
      capture_io(fn ->
        Copy.run(["source_db", "--repo", inspect(RepoWithUrl), "--force"])
      end)

    assert output =~ "source: postgres://*****@db.local:5544/source_db"
    assert output =~ "target: postgres://*****@db.local:5544/target_db"
  end

  test "supports username without password and missing host or port defaults" do
    Process.put(:db_copy_cmd_results, [{"0\n", 0}, {"dumped", 0}, {"restored", 0}])

    output =
      capture_io(fn ->
        Copy.run(["source_db", "--repo", inspect(RepoWithoutPassword)])
      end)

    assert output =~ "target: postgres://*****@db.local:5432/target_db"

    Process.put(:db_copy_cmd_results, [{"0\n", 0}, {"dumped", 0}, {"restored", 0}])

    output =
      capture_io(fn ->
        Copy.run(["source_db", "--repo", inspect(RepoWithoutCredentials)])
      end)

    assert output =~ "target: postgres://*****@localhost:5432/target_db"
  end

  test "raises when psql is unavailable" do
    Application.put_env(:zaq, Copy, system: MissingPsqlSystem)

    assert_raise Mix.Error, "psql not found", fn ->
      Copy.run(["source_db", "--repo", inspect(RepoWithoutUrl)])
    end
  end

  test "raises when target inspection fails or target has tables" do
    Process.put(:db_copy_cmd_results, [{"bad target", 1}])

    assert_raise Mix.Error, ~r/Could not inspect target database:\nbad target/, fn ->
      Copy.run(["source_db", "--repo", inspect(RepoWithoutUrl)])
    end

    Process.put(:db_copy_cmd_results, [{"2\n", 0}])

    assert_raise Mix.Error, ~r/Target database is not empty/, fn ->
      Copy.run(["source_db", "--repo", inspect(RepoWithoutUrl)])
    end
  end

  test "raises when dump or restore tooling fails" do
    Process.put(:db_copy_cmd_results, [{"0\n", 0}, {"dump failed", 1}])

    assert_raise Mix.Error, ~r/pg_dump failed:\ndump failed/, fn ->
      Copy.run(["source_db", "--repo", inspect(RepoWithoutUrl)])
    end

    Process.put(:db_copy_cmd_results, [{"0\n", 0}, {"dumped", 0}, {"restore failed", 1}])

    assert_raise Mix.Error, ~r/pg_restore failed:\nrestore failed/, fn ->
      capture_io(fn ->
        Copy.run(["source_db", "--repo", inspect(RepoWithoutUrl)])
      end)
    end
  end

  test "raises when pg_restore is unavailable" do
    Application.put_env(:zaq, Copy, system: MissingPgRestoreSystem)

    assert_raise Mix.Error, "pg_restore not found", fn ->
      Copy.run(["source_db", "--repo", inspect(RepoWithoutUrl), "--force"])
    end
  end
end
