defmodule Zaq.Accounts.BOAuthorizationTest do
  use Zaq.DataCase, async: true

  alias Zaq.Accounts
  alias Zaq.Accounts.BOAuthorization
  alias Zaq.Events.TrustedContext

  defp active_user(role) do
    user_fixture(%{role: role, must_change_password: false})
  end

  test "existing super_admin role authorizes policy operations without a Person" do
    user = active_user(role_fixture(%{name: "super_admin"}))
    actor = %{kind: :bo_user, subject: to_string(user.id), user_id: user.id}

    for operation <- [
          :view_resource_policies,
          :add_resource_policies,
          :edit_resource_policies,
          :manage_confidentiality_defaults,
          :manage_roles
        ] do
      assert {:ok, current} = BOAuthorization.authorize(actor, operation)
      assert current.id == user.id
    end

    assert {:ok, %TrustedContext{actor: ^actor, skip_actor_clearance: true}} =
             TrustedContext.from_bo_actor(actor)
  end

  test "role permissions grant only named policy operations, not account administration" do
    role =
      role_fixture(%{
        meta: %{"permissions" => ["view_resource_policies", "manage_roles", "read"]}
      })

    user = active_user(role)
    actor = %{user_id: user.id}
    assert {:ok, _} = BOAuthorization.authorize(actor, :view_resource_policies)

    for operation <- [:edit_resource_policies, :manage_roles, :unknown, "view_resource_policies"] do
      assert BOAuthorization.authorize(actor, operation) == {:error, :unauthorized}
    end

    assert {:ok, %TrustedContext{skip_actor_clearance: false}} =
             TrustedContext.from_bo_actor(actor)
  end

  test "actor role/bypass claims and ordinary role assignment never grant policy authority" do
    user = active_user(role_fixture())

    actor = %{
      user_id: user.id,
      role: %{name: "super_admin"},
      skip_permissions: true,
      skip_actor_clearance: true
    }

    assert BOAuthorization.authorize(actor, :edit_resource_policies) == {:error, :unauthorized}
    assert {:ok, context} = TrustedContext.from_bo_actor(actor)
    refute context.skip_permissions
    refute context.skip_actor_clearance
    refute Map.has_key?(context.actor, :skip_permissions)
    opts = TrustedContext.event_builder_opts(context)
    event = Zaq.Event.new(%{}, :engine, actor: opts[:actor], opts: opts[:event_opts])
    refute TrustedContext.from_event(event).skip_permissions
    refute TrustedContext.from_event(event).skip_actor_clearance
  end

  test "current persisted role and password state are read again on each decision" do
    user = active_user(role_fixture(%{name: "super_admin"}))
    actor = %{user_id: user.id}
    assert {:ok, _} = BOAuthorization.authorize(actor, :manage_roles)

    role = role_fixture()
    {:ok, user} = Accounts.update_user(user, %{role_id: role.id})
    assert BOAuthorization.authorize(actor, :manage_roles) == {:error, :unauthorized}

    {:ok, _} = Accounts.update_user(user, %{must_change_password: true})
    assert TrustedContext.from_bo_actor(actor) == {:error, :unauthorized}
  end

  test "missing deleted and password-blocked users fail closed" do
    user = user_fixture()

    for actor <- [
          nil,
          %{},
          %{user_id: 0},
          %{user_id: user.id}
        ] do
      assert BOAuthorization.authorize(actor, :view_resource_policies) == {:error, :unauthorized}
      assert TrustedContext.from_bo_actor(actor) == {:error, :unauthorized}
    end

    {:ok, _} = Accounts.delete_user(user)

    assert BOAuthorization.authorize(%{user_id: user.id}, :view_resource_policies) ==
             {:error, :unauthorized}
  end

  test "clearance escape is an explicit role capability independent of policy edits" do
    user = active_user(role_fixture(%{meta: %{"permissions" => ["skip_actor_clearance"]}}))
    actor = %{user_id: user.id}

    assert {:ok, %TrustedContext{skip_actor_clearance: true, skip_permissions: false}} =
             TrustedContext.from_bo_actor(actor)

    assert BOAuthorization.authorize(actor, :edit_resource_policies) == {:error, :unauthorized}
  end

  test "execution context rechecks the clearance capability after role revocation" do
    role = role_fixture(%{meta: %{"permissions" => ["skip_actor_clearance"]}})
    user = active_user(role)
    actor = %{"user_id" => to_string(user.id), "role" => %{"name" => "super_admin"}}

    assert {:ok, %TrustedContext{skip_actor_clearance: true}} =
             TrustedContext.from_bo_actor(actor)

    {:ok, _} = Accounts.update_role(role, %{meta: %{}})

    assert {:ok, %TrustedContext{skip_actor_clearance: false}} =
             TrustedContext.from_bo_actor(actor)
  end
end
