defmodule Zaq.Engine.AccountAdministrationTest do
  use Zaq.DataCase, async: true

  @moduletag capture_log: true

  alias Zaq.Accounts
  alias Zaq.Engine.Api
  alias Zaq.Engine.Notifications.NotificationLog
  alias Zaq.Event

  test "Engine route retains trusted actor rather than request claims" do
    user = user_fixture(%{must_change_password: false})
    role = role_fixture(%{name: "super_admin"})
    admin = user_fixture(%{role: role, must_change_password: false})

    request = %{
      operation: :create_role,
      params: %{name: "action_role", actor: %{user_id: admin.id}}
    }

    event = Event.new(request, :engine, actor: %{user_id: user.id}, opts: [confidential: true])

    assert %{response: {:error, :unauthorized}} =
             Api.handle_event(event, :account_administration, %{})

    refute Accounts.get_role_by_name("action_role")

    assert %{response: {:ok, %{name: "action_role"}}} =
             Api.handle_event(
               %{event | actor: %{user_id: admin.id}},
               :account_administration,
               %{}
             )
  end

  test "mutation event must suppress its password-bearing payload" do
    user =
      user_fixture(%{role: role_fixture(%{name: "super_admin"}), must_change_password: false})

    event =
      Event.new(%{operation: :create_role, params: %{name: "hidden"}}, :engine,
        actor: %{user_id: user.id}
      )

    assert %{response: {:error, :confidential_event_required}} =
             Api.handle_event(event, :account_administration, %{})
  end

  test "invalid requests and undeclared operations cannot mutate accounts" do
    admin =
      user_fixture(%{role: role_fixture(%{name: "super_admin"}), must_change_password: false})

    for request <- [
          nil,
          [],
          %{},
          %{operation: :create_role},
          %{operation: :create_role, params: []}
        ] do
      event = Event.new(request, :engine, actor: %{user_id: admin.id}, opts: [confidential: true])

      assert %{response: {:error, :invalid_request}} =
               Api.handle_event(event, :account_administration, %{})
    end

    event =
      Event.new(%{operation: :delete_all, params: %{}}, :engine,
        actor: %{user_id: admin.id},
        opts: [confidential: true]
      )

    assert %{response: {:error, :invalid_operation}} =
             Api.handle_event(event, :account_administration, %{})
  end

  test "successful creation reuses welcome delivery and invalid creation sends nothing" do
    admin =
      user_fixture(%{role: role_fixture(%{name: "super_admin"}), must_change_password: false})

    request = %{
      operation: :create_user,
      params: %{
        username: "welcomed_user",
        email: "welcomed@example.com",
        role_id: admin.role_id,
        password: "StrongPass1!"
      }
    }

    event = Event.new(request, :engine, actor: %{user_id: admin.id}, opts: [confidential: true])
    assert %{response: {:ok, user}} = Api.handle_event(event, :account_administration, %{})
    assert Accounts.get_user!(user.id).email == "welcomed@example.com"

    assert %{payload: %{"subject" => "Welcome to ZAQ — your account is ready"}} =
             Repo.get_by!(NotificationLog,
               sender: "welcome",
               recipient_ref_type: "user",
               recipient_ref_id: user.id
             )

    before = Repo.aggregate(NotificationLog, :count)

    assert %{response: {:error, %Ecto.Changeset{}}} =
             Api.handle_event(event, :account_administration, %{})

    assert Repo.aggregate(NotificationLog, :count) == before
  end
end
