defmodule ZaqWeb.Live.BO.Accounts.ProfileLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts

  setup %{conn: conn} do
    role = role_fixture(%{name: "profile_role"})
    user = user_fixture(%{username: "profile_user", email: "profile@example.com", role: role})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    user = Accounts.get_user!(user.id)

    conn = init_test_session(conn, %{user_id: user.id})

    %{conn: conn, user: user}
  end

  test "renders current user information", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/bo/profile")

    assert has_element?(view, "#profile-username", user.username)
    assert has_element?(view, "#profile-email", user.email)
    assert has_element?(view, "#profile-role", user.role.name)
    assert has_element?(view, "#profile-password-status-active")
  end

  test "edit profile button points to current user edit page", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/bo/profile")

    assert has_element?(view, ~s{#edit-profile-button[href="/bo/users/#{user.id}/edit"]})
  end

  test "header user menu links to profile page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

    assert has_element?(view, "#header-user-menu")
    assert has_element?(view, ~s{#header-profile-link[href="/bo/profile"]})
  end
end
