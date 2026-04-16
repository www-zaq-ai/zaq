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

  test "rollback/2 executes down migrator path and returns ok tuple" do
    # Pass a far-future version so Ecto finds no applied migrations to reverse —
    # the DB schema is untouched, but Application.ensure_all_started/1 and
    # Ecto.Migrator.with_repo/2 are both executed, covering both lines.
    future_version = 99_999_999_999_999
    assert {:ok, _, _} = Release.rollback(Zaq.Repo, future_version)
  end
end
