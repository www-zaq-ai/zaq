defmodule ZaqWeb.Live.BO.Accounts.UsersLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures
  alias Zaq.Accounts

  setup %{conn: conn} do
    user = user_fixture(%{username: "testadmin"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

    conn = conn |> init_test_session(%{user_id: user.id})
    %{conn: conn, user: user}
  end

  test "lists users", %{conn: conn, user: user} do
    {:ok, _view, html} = live(conn, ~p"/bo/users")
    assert html =~ user.username
  end

  test "deletes a user", %{conn: conn} do
    target = user_fixture(%{username: "to_delete"})
    {:ok, view, _html} = live(conn, ~p"/bo/users")

    view
    |> element(~s{button[phx-value-id="#{target.id}"]})
    |> render_click()

    refute render(view) =~ "to_delete"
  end

  test "navigates to new user form", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/bo/users/new")
    assert html =~ "Create a new user"
  end

  test "creates a new user", %{conn: conn} do
    role = role_fixture(%{name: "staff"})
    {:ok, view, _html} = live(conn, ~p"/bo/users/new")

    view
    |> form(~s{form[phx-submit="save"]},
      user: %{username: "newuser", password: "StrongPass1!", role_id: role.id}
    )
    |> render_submit()

    assert_redirect(view, ~p"/bo/users")
  end

  test "navigates to edit user form", %{conn: conn} do
    target = user_fixture(%{username: "editable"})
    {:ok, _view, html} = live(conn, ~p"/bo/users/#{target.id}/edit")
    assert html =~ "Edit user"
    assert html =~ "editable"
  end
end
