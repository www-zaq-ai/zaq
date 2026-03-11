defmodule ZaqWeb.Live.BO.LoginLiveTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  test "renders login form when no user is in session", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/login")

    assert has_element?(view, ~s(form[action="/bo/session"][method="post"]))
    assert has_element?(view, ~s(input[name="username"]))
    assert has_element?(view, ~s(input[name="password"]))
  end

  test "redirects to change-password when logged user must change password", %{conn: conn} do
    user = user_fixture(%{username: "bo_login_redirect_change"})
    conn = init_test_session(conn, %{user_id: user.id})

    assert {:error, {:live_redirect, %{to: "/bo/change-password"}}} = live(conn, ~p"/bo/login")
  end

  test "redirects to dashboard when logged user already changed password", %{conn: conn} do
    user = user_fixture(%{username: "bo_login_redirect_dashboard"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    conn = init_test_session(conn, %{user_id: user.id})

    assert {:error, {:live_redirect, %{to: "/bo/dashboard"}}} = live(conn, ~p"/bo/login")
  end

  test "validate event updates the form assign", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/login")

    _ = render_hook(view, "validate", %{"username" => "alice", "password" => "secret"})

    assert has_element?(view, ~s(input[name="username"][value="alice"]))
  end
end
