defmodule ZaqWeb.Live.BO.Accounts.UserFormLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    admin = user_fixture(%{username: "user_form_admin"})
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: admin.id})

    %{conn: conn}
  end

  test "validates required fields on new form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/users/new")

    view
    |> form("form[phx-submit='save']", user: %{username: "", password: "", role_id: ""})
    |> render_change()

    assert has_element?(view, "p", "can't be blank")
  end

  test "creates a user and redirects", %{conn: conn} do
    role = role_fixture(%{name: "lane6_staff"})

    {:ok, view, _html} = live(conn, ~p"/bo/users/new")

    view
    |> form("form[phx-submit='save']",
      user: %{username: "lane6_user", password: "StrongPass1!", role_id: role.id}
    )
    |> render_submit()

    assert_redirect(view, ~p"/bo/users")

    created = Accounts.get_user_by_username("lane6_user")
    assert created
    assert created.role_id == role.id
  end

  test "edits a user without requiring password", %{conn: conn} do
    role = role_fixture(%{name: "lane6_editor"})
    user = user_fixture(%{username: "lane6_edit_me", role: role})

    {:ok, view, _html} = live(conn, ~p"/bo/users/#{user.id}/edit")

    refute has_element?(view, "input[name='user[password]']")

    view
    |> form("form[phx-submit='save']",
      user: %{username: "lane6_edited", role_id: role.id}
    )
    |> render_submit()

    assert_redirect(view, ~p"/bo/users")
    assert Accounts.get_user!(user.id).username == "lane6_edited"
  end

  test "new save with invalid params stays on form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/users/new")

    view
    |> form("form[phx-submit='save']", user: %{username: "", password: "", role_id: ""})
    |> render_submit()

    assert has_element?(view, "p", "can't be blank")
  end

  test "edit save with invalid params stays on form", %{conn: conn} do
    role = role_fixture(%{name: "lane6_user_edit_invalid_role"})
    user = user_fixture(%{username: "lane6_edit_invalid_user", role: role})

    {:ok, view, _html} = live(conn, ~p"/bo/users/#{user.id}/edit")

    view
    |> form("form[phx-submit='save']", user: %{username: "", role_id: ""})
    |> render_submit()

    assert has_element?(view, "p", "can't be blank")
  end
end
