defmodule ZaqWeb.Live.BO.System.ChangePasswordLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  test "allows users with must_change_password to access change-password", %{conn: conn} do
    user = user_fixture(%{username: "must_change_password_user"})
    conn = init_test_session(conn, %{user_id: user.id})

    {:ok, view, _html} = live(conn, ~p"/bo/change-password")

    assert has_element?(view, ~s(form[phx-submit="change_password"]))
  end

  test "redirects users with must_change_password from dashboard to change-password", %{
    conn: conn
  } do
    user = user_fixture(%{username: "must_change_password_redirect_user"})
    conn = init_test_session(conn, %{user_id: user.id})

    assert {:error, {_, %{to: "/bo/change-password"}}} = live(conn, ~p"/bo/dashboard")
  end
end
