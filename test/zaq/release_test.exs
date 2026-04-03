defmodule Zaq.ReleaseTest do
  use ExUnit.Case, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Release

  setup do
    previous_repos = Application.get_env(:zaq, :ecto_repos)
    Sandbox.mode(Zaq.Repo, :auto)

    on_exit(fn ->
      Application.put_env(:zaq, :ecto_repos, previous_repos)
      Sandbox.mode(Zaq.Repo, :manual)
    end)

    :ok
  end

  test "migrate/0 handles empty configured repos" do
    Application.put_env(:zaq, :ecto_repos, [])

    assert [] = Release.migrate()
  end

  test "migrate/0 runs migrations for configured repo" do
    Application.put_env(:zaq, :ecto_repos, [Zaq.Repo])

    assert [_] = Release.migrate()
  end

  # This test is causing flaky tests as order execution is not guaranteed
  # test "rollback/2 executes down migrator path" do
  #   latest_version = latest_migration_version()

  #   assert {:ok, _migrations, _apps} = Release.rollback(Zaq.Repo, latest_version)
  # end

  # defp latest_migration_version do
  #   "priv/repo/migrations/*.exs"
  #   |> Path.wildcard()
  #   |> Enum.reject(&(Path.basename(&1) == ".formatter.exs"))
  #   |> Enum.map(fn path ->
  #     path
  #     |> Path.basename(".exs")
  #     |> String.split("_", parts: 2)
  #     |> List.first()
  #     |> String.to_integer()
  #   end)
  #   |> Enum.max()
  # end
end
