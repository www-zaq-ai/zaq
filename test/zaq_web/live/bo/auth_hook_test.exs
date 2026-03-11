defmodule ZaqWeb.Live.BO.AuthHookTest do
  use ZaqWeb.ConnCase, async: true

  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias ZaqWeb.Live.BO.AuthHook

  test "halts and redirects to login when there is no session user" do
    socket = %Phoenix.LiveView.Socket{view: ZaqWeb.Live.BO.DashboardLive}

    assert {:halt, halted_socket} = AuthHook.on_mount(:default, %{}, %{}, socket)
    assert {:live, :redirect, %{to: "/bo/login", kind: :push}} = halted_socket.redirected
  end

  test "halts and redirects to change-password when user must rotate password" do
    user = user_fixture(%{username: "bo_auth_hook_force_change"})
    socket = %Phoenix.LiveView.Socket{view: ZaqWeb.Live.BO.DashboardLive}

    assert {:halt, halted_socket} =
             AuthHook.on_mount(:default, %{}, %{"user_id" => user.id}, socket)

    assert {:live, :redirect, %{to: "/bo/change-password", kind: :push}} =
             halted_socket.redirected
  end

  test "continues on change-password route for users that must rotate password" do
    user = user_fixture(%{username: "bo_auth_hook_change_route"})
    socket = %Phoenix.LiveView.Socket{view: ZaqWeb.Live.Bo.System.ChangePasswordLive}

    assert {:cont, continued_socket} =
             AuthHook.on_mount(:default, %{}, %{"user_id" => user.id}, socket)

    assert continued_socket.assigns.current_user.id == user.id
  end

  test "continues and assigns current_user when password was already changed" do
    user = user_fixture(%{username: "bo_auth_hook_valid_user"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    socket = %Phoenix.LiveView.Socket{view: ZaqWeb.Live.BO.DashboardLive}

    assert {:cont, continued_socket} =
             AuthHook.on_mount(:default, %{}, %{"user_id" => user.id}, socket)

    assert continued_socket.assigns.current_user.id == user.id
  end
end
