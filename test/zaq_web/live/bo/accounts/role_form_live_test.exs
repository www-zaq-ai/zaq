defmodule ZaqWeb.Live.BO.Accounts.RoleFormLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    admin = user_fixture(%{username: "role_form_admin"})
    {:ok, admin} = Accounts.change_password(admin, %{password: "StrongPass1!"})

    conn = init_test_session(conn, %{user_id: admin.id})

    %{conn: conn}
  end

  test "validates required name on new form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/roles/new")

    view
    |> form("form[phx-submit='save']", role: %{name: "", meta: ""})
    |> render_change()

    assert has_element?(view, "p", "can't be blank")
  end

  test "creates a role with JSON meta", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/roles/new")

    view
    |> form("form[phx-submit='save']",
      role: %{name: "lane6_role", meta: ~s({"permissions":["read","write"]})}
    )
    |> render_submit()

    assert_redirect(view, ~p"/bo/roles")

    role = Accounts.get_role_by_name("lane6_role")
    assert role
    assert role.meta == %{"permissions" => ["read", "write"]}
  end

  test "edits role and falls back to empty meta for invalid JSON", %{conn: conn} do
    role = role_fixture(%{name: "lane6_edit_role"})

    {:ok, view, _html} = live(conn, ~p"/bo/roles/#{role.id}/edit")

    view
    |> form("form[phx-submit='save']",
      role: %{name: "lane6_edited_role", meta: "{invalid json"}
    )
    |> render_submit()

    assert_redirect(view, ~p"/bo/roles")

    updated = Accounts.get_role!(role.id)
    assert updated.name == "lane6_edited_role"
    assert updated.meta == %{}
  end

  test "new save with invalid params stays on form", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/roles/new")

    view
    |> form("form[phx-submit='save']", role: %{name: "", meta: ""})
    |> render_submit()

    refute_redirected(view)
    assert has_element?(view, "p", "can't be blank")
  end

  test "edit save with invalid params stays on form", %{conn: conn} do
    role = role_fixture(%{name: "lane6_edit_invalid"})
    {:ok, view, _html} = live(conn, ~p"/bo/roles/#{role.id}/edit")

    view
    |> form("form[phx-submit='save']", role: %{name: "", meta: "{}"})
    |> render_submit()

    refute_redirected(view)
    assert has_element?(view, "p", "can't be blank")
  end
end
