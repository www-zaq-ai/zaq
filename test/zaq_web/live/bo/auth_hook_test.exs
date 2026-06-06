defmodule ZaqWeb.Live.BO.AuthHookTest do
  use ZaqWeb.ConnCase

  import Zaq.AccountsFixtures
  import Phoenix.LiveViewTest

  alias Zaq.Accounts
  alias ZaqWeb.Live.BO.AuthHook

  defp build_socket(view) do
    %Phoenix.LiveView.Socket{
      view: view,
      private: %{
        live_temp: %{},
        lifecycle: %Phoenix.LiveView.Lifecycle{}
      }
    }
  end

  test "halts and redirects to login when there is no session user" do
    socket = build_socket(ZaqWeb.Live.BO.DashboardLive)

    assert {:halt, halted_socket} = AuthHook.on_mount(:default, %{}, %{}, socket)
    assert {:live, :redirect, %{to: "/bo/login", kind: :push}} = halted_socket.redirected
  end

  test "halts and redirects to change-password when user must rotate password" do
    user = user_fixture(%{username: "bo_auth_hook_force_change"})
    socket = build_socket(ZaqWeb.Live.BO.DashboardLive)

    assert {:halt, halted_socket} =
             AuthHook.on_mount(:default, %{}, %{"user_id" => user.id}, socket)

    assert {:live, :redirect, %{to: "/bo/change-password", kind: :push}} =
             halted_socket.redirected
  end

  test "continues on change-password route for users that must rotate password" do
    user = user_fixture(%{username: "bo_auth_hook_change_route"})
    socket = build_socket(ZaqWeb.Live.BO.System.ChangePasswordLive)

    assert {:cont, continued_socket} =
             AuthHook.on_mount(:default, %{}, %{"user_id" => user.id}, socket)

    assert continued_socket.assigns.current_user.id == user.id
  end

  test "continues and assigns current_user when password was already changed" do
    user = user_fixture(%{username: "bo_auth_hook_valid_user"})
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    socket = build_socket(ZaqWeb.Live.BO.DashboardLive)

    assert {:cont, continued_socket} =
             AuthHook.on_mount(:default, %{}, %{"user_id" => user.id}, socket)

    assert continued_socket.assigns.current_user.id == user.id
  end

  describe "addons pubsub updates" do
    setup %{conn: conn} do
      user = user_fixture(%{username: "bo_auth_hook_pubsub"})
      {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})

      %{conn: init_test_session(conn, %{user_id: user.id}), user: user}
    end

    test "increments features_version on addons_updated broadcasts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/bo/dashboard")

      initial_state = :sys.get_state(view.pid)
      assert initial_state.socket.assigns.features_version == 0

      Phoenix.PubSub.broadcast(Zaq.PubSub, "addons:updated", :addons_updated)

      render(view)

      updated_state = :sys.get_state(view.pid)
      assert updated_state.socket.assigns.features_version == 1
    end
  end
end
