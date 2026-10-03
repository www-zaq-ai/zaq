defmodule Zaq.Engine.History.MembershipOrderTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Zaq.Engine.History.MembershipOrder

  property "per-member latest revisions win regardless of event arrival order" do
    check all(
            events <-
              list_of(tuple({member_of(["alice", "bob"]), member_of([:add, :remove])}),
                min_length: 1,
                max_length: 40
              )
          ) do
      ordered = Enum.with_index(events)

      expected =
        Enum.reduce(ordered, %{}, fn {{member, operation}, _}, acc ->
          Map.put(acc, member, operation)
        end)

      for sequence <- [
            ordered,
            Enum.reverse(ordered),
            Enum.sort_by(ordered, fn {_, revision} -> rem(revision, 3) end)
          ] do
        state =
          Enum.reduce(sequence, %{}, fn {{member, operation}, revision}, state ->
            assert {:ok, _, next} =
                     MembershipOrder.event(state, "platform", member, operation, revision)

            next
          end)

        actual =
          expected
          |> Enum.filter(fn {_, op} -> op == :add end)
          |> Enum.map(&elem(&1, 0))
          |> Enum.sort()

        assert state["members"] == actual
      end
    end
  end

  test "targeted snapshots fence only their selected members" do
    snapshot = %{identity_platform: "platform", revision: 20, member_ids: ["alice"]}
    assert {:ok, _, state} = MembershipOrder.snapshot(%{}, snapshot, ["alice"])
    assert {:ok, :stale, ^state} = MembershipOrder.event(state, "platform", "alice", :remove, 19)
    assert {:ok, :applied, next} = MembershipOrder.event(state, "platform", "bob", :add, 19)
    assert next["members"] == ["alice", "bob"]
  end

  test "unversioned history needs a versioned snapshot before accepting ordered events" do
    snapshot = %{identity_platform: "platform", member_ids: []}
    assert {:ok, [], state} = MembershipOrder.snapshot(%{}, snapshot, :all)

    assert {:error, :unordered_snapshot} =
             MembershipOrder.event(state, "platform", "alice", :add, 1)

    assert {:ok, [], state} =
             MembershipOrder.snapshot(state, Map.put(snapshot, :revision, 2), :all)

    assert {:ok, :stale, ^state} = MembershipOrder.event(state, "platform", "alice", :add, 1)
  end

  test "duplicate snapshot revisions cannot change the established audience" do
    snapshot = %{identity_platform: "platform", revision: 20, member_ids: []}
    assert {:ok, [], state} = MembershipOrder.snapshot(%{}, snapshot, :all)

    assert {:ok, [], ^state} =
             MembershipOrder.snapshot(state, %{snapshot | member_ids: ["alice"]}, :all)

    assert {:ok, :applied, state} = MembershipOrder.event(%{}, "platform", "alice", :remove, 20)

    assert {:ok, [], _} =
             MembershipOrder.snapshot(state, %{snapshot | member_ids: ["alice"]}, ["alice"])
  end
end
