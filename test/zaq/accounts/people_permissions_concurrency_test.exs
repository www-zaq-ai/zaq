defmodule Zaq.Accounts.PeoplePermissionsConcurrencyTest do
  # Separate connections must observe committed data. Serialize this narrow suite
  # so its global grant cannot enter another test's default-deny snapshot.
  use ExUnit.Case, async: false
  alias Ecto.Adapters.SQL.Sandbox
  alias Zaq.Accounts.{People, PeoplePermissionGrant, PeoplePermissions}
  alias Zaq.Repo
  import Ecto.Query

  test "concurrent grants converge and opposing desired writes retain uniqueness" do
    Sandbox.unboxed_run(Repo, fn ->
      assert Repo.all(from g in PeoplePermissionGrant, where: g.scope_type == "all_people") == []

      {:ok, team} =
        People.create_team(%{name: "Permission race #{System.unique_integer([:positive])}"})

      try do
        for scope <- [:all_people, {:team, team.id}] do
          [first, second] =
            race(
              fn -> PeoplePermissions.grant(scope, :access_profile) end,
              fn -> PeoplePermissions.grant(scope, :access_profile) end
            )

          assert {:ok, a} = first
          assert {:ok, b} = second
          assert a.id == b.id
          assert a.inserted_at == b.inserted_at

          results =
            race(
              fn -> PeoplePermissions.grant(scope, :access_profile) end,
              fn -> PeoplePermissions.revoke(scope, :access_profile) end
            )

          assert Enum.all?(results, &match?({:ok, _}, &1))
          assert {:ok, _} = PeoplePermissions.grant(scope, :access_profile)
          assert {:ok, 1} = PeoplePermissions.revoke(scope, :access_profile)
          assert {:ok, 0} = PeoplePermissions.revoke(scope, :access_profile)
        end
      after
        PeoplePermissions.revoke(:all_people, :access_profile)
        People.delete_team(team)
      end
    end)
  end

  defp race(left, right) do
    parent = self()

    tasks =
      Enum.map([left, right], fn operation ->
        Task.async(fn -> run_race(parent, operation) end)
      end)

    for task <- tasks do
      pid = task.pid
      assert_receive {:ready, ^pid}, 5_000
    end

    for task <- tasks, do: send(task.pid, :go)
    Enum.map(tasks, &Task.await(&1, 10_000))
  end

  defp await_race(parent, operation) do
    send(parent, {:ready, self()})

    receive do
      :go -> operation.()
    after
      5_000 -> flunk("race was not released")
    end
  end

  defp run_race(parent, operation) do
    Sandbox.unboxed_run(Repo, fn -> await_race(parent, operation) end)
  end
end
