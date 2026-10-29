defmodule ZaqWeb.Live.BO.Accounts.RoleAuthorizationTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{must_change_password: false})
    %{conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "ordinary BO user cannot create a role through a forged save", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/roles/new")
    render_submit(view, "save", %{"role" => %{"name" => "forged_role", "meta" => "{}"}})
    refute Accounts.get_role_by_name("forged_role")
    assert render(view) =~ "not authorized"
  end

  test "ordinary BO user cannot edit or delete another role", %{conn: conn} do
    role = role_fixture()
    {:ok, editor, _} = live(conn, ~p"/bo/roles/#{role.id}/edit")

    render_submit(editor, "save", %{
      "role" => %{"name" => role.name, "meta" => ~s({"permissions":["edit_resource_policies"]})}
    })

    assert Accounts.get_role!(role.id).meta == %{}
    {:ok, list, _} = live(conn, ~p"/bo/roles")
    render_click(list, "delete", %{"id" => to_string(role.id)})
    assert Accounts.get_role!(role.id)
  end

  test "ordinary user cannot promote themselves or create a privileged account", %{
    conn: conn,
    user: user
  } do
    role = role_fixture(%{name: "super_admin"})
    {:ok, view, _} = live(conn, ~p"/bo/users/#{user.id}/edit")

    render_submit(view, "save", %{"user" => %{"username" => user.username, "role_id" => role.id}})
    assert Accounts.get_user!(user.id).role_id == user.role_id
    assert render(view) =~ "not authorized"

    {:ok, creator, _} = live(conn, ~p"/bo/users/new")

    render_submit(creator, "save", %{
      "user" => %{
        "username" => "forged_admin",
        "email" => "forged_admin@example.com",
        "password" => "StrongPass1!",
        "role_id" => role.id
      }
    })

    refute Accounts.get_user_by_username("forged_admin")
  end

  test "a live admin session loses mutation authority when its saved role is revoked", %{
    conn: conn
  } do
    admin =
      user_fixture(%{role: role_fixture(%{name: "super_admin"}), must_change_password: false})

    conn = init_test_session(conn, %{user_id: admin.id})
    {:ok, view, _} = live(conn, ~p"/bo/roles/new")
    Accounts.update_user(admin, %{role_id: role_fixture().id})
    render_submit(view, "save", %{"role" => %{"name" => "revoked_role", "meta" => "{}"}})
    refute Accounts.get_role_by_name("revoked_role")
    assert render(view) =~ "not authorized"
  end
end
