defmodule Zaq.ResourcePolicies.FoundationTest do
  use Zaq.DataCase, async: true

  alias Zaq.Permissions.ResourcePolicy
  alias Zaq.ResourcePolicies

  test "foundation is not deployment readiness and exposes no mutation switch" do
    assert ResourcePolicies.ready?() == false
  end

  test "internal lookup distinguishes invalid resource from a valid unset policy" do
    ref = {"storage_entry", "00000000-0000-4000-8000-000000000012"}
    assert ResourcePolicies.fetch(ref) == {:ok, nil}
    assert ResourcePolicies.fetch({"unknown", 12}) == {:error, :invalid_resource}

    {:ok, policy} =
      %ResourcePolicy{}
      |> ResourcePolicy.changeset(%{
        resource_type: "storage_entry",
        resource_id: elem(ref, 1),
        clearance_level: 2
      })
      |> Repo.insert()

    assert {:ok, ^policy} = ResourcePolicies.fetch(ref)
  end

  test "internal lookup never turns a database failure into an unset policy" do
    parent = self()

    {pid, monitor} =
      spawn_monitor(fn ->
        result =
          try do
            ResourcePolicies.fetch({"person", 12})
          rescue
            error -> {:raised, error.__struct__}
          end

        send(parent, {:lookup_result, result})
      end)

    assert_receive {:lookup_result, {:raised, DBConnection.OwnershipError}}, 5_000
    assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 5_000
  end
end
