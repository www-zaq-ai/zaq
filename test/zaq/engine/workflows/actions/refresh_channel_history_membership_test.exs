defmodule Zaq.Engine.Workflows.Actions.RefreshChannelHistoryMembershipTest do
  use Zaq.DataCase, async: true

  import Zaq.AccountsFixtures

  alias Zaq.Engine.Workflows.Actions.RefreshChannelHistoryMembership

  test "requires a currently authorized super-admin, not a claimed ID or a missing actor" do
    id = Ecto.UUID.generate()

    for context <- [%{}, %{actor: %{user_id: -1}}, %{actor: %{person_id: 1}}] do
      assert {:error, :unauthorized} =
               RefreshChannelHistoryMembership.run(%{transcript_id: id}, context)
    end
  end

  test "rejects non-map params and context even for a persisted super-admin" do
    admin = super_admin_fixture()

    assert {:error, :unauthorized} =
             RefreshChannelHistoryMembership.run(nil, %{actor: %{user_id: admin.id}})

    assert {:error, :unauthorized} =
             RefreshChannelHistoryMembership.run(
               %{transcript_id: Ecto.UUID.generate()},
               nil
             )
  end

  test "rejects invalid transcript IDs before attempting a provider snapshot" do
    admin = super_admin_fixture()
    staff = user_fixture()

    assert {:error, :unauthorized} =
             RefreshChannelHistoryMembership.run(
               %{transcript_id: Ecto.UUID.generate()},
               %{actor: %{user_id: staff.id}}
             )

    assert {:error, :not_found} =
             RefreshChannelHistoryMembership.run(
               %{transcript_id: "invalid"},
               %{actor: %{user_id: admin.id}}
             )
  end

  test "Person scope retains operation authorization and rejects ambiguous scopes" do
    admin = super_admin_fixture()
    staff = user_fixture()
    scope = %{person_id: 123, channel_config_id: 456}

    for actor <- [%{}, %{user_id: staff.id}] do
      assert {:error, :unauthorized} = RefreshChannelHistoryMembership.run(scope, %{actor: actor})
    end

    assert {:error, :invalid_scope} =
             RefreshChannelHistoryMembership.run(
               Map.put(scope, :transcript_id, Ecto.UUID.generate()),
               %{actor: %{user_id: admin.id}}
             )

    assert {:error, :invalid_person} =
             RefreshChannelHistoryMembership.run(scope, %{actor: %{user_id: admin.id}})
  end

  test "rejects missing person scope selectors for an authorized super-admin" do
    admin = super_admin_fixture()

    assert {:error, :invalid_scope} =
             RefreshChannelHistoryMembership.run(%{}, %{actor: %{user_id: admin.id}})
  end
end
