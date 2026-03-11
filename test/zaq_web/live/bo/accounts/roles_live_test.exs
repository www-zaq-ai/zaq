defmodule ZaqWeb.Live.BO.Accounts.RolesLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{username: "rolesadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = conn |> init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  test "lists roles", %{conn: conn} do
    role = role_fixture(%{name: "visible_role"})
    {:ok, _view, html} = live(conn, ~p"/bo/roles")
    assert html =~ role.name
  end

  test "navigates to new role form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/bo/roles/new")
    assert html =~ "Create a new role"
  end

  test "creates a new role", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/roles/new")

    view
    |> form(~s{form[phx-submit="save"]}, role: %{name: "new_role"})
    |> render_submit()

    assert_redirect(view, ~p"/bo/roles")
  end

  test "navigates to edit role form", %{conn: conn} do
    role = role_fixture(%{name: "edit_me"})
    {:ok, _view, html} = live(conn, ~p"/bo/roles/#{role.id}/edit")
    assert html =~ "Edit role"
    assert html =~ "edit_me"
  end

  test "deletes a role", %{conn: conn} do
    role = role_fixture(%{name: "delete_me"})
    {:ok, view, _html} = live(conn, ~p"/bo/roles")

    view
    |> element(~s{button[phx-value-id="#{role.id}"]})
    |> render_click()

    refute render(view) =~ "delete_me"
  end
end
