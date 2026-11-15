defmodule ZaqWeb.Live.BO.System.GrpcSettingsLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.System, as: SystemConfig

  setup %{conn: conn} do
    user = user_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "Global shows the 64 MiB default and saves through Engine without changing the running VM",
       %{conn: conn} do
    original = Application.get_env(:grpc, :max_message_length)
    {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=global")
    assert has_element?(view, "#global-grpc-limit-input[value='64']")
    assert render(view) =~ "Engine restart required"

    view
    |> form("#global-grpc-limit-form", grpc_max_message_mib: "8")
    |> render_submit()

    assert {:ok, 8_388_608} = SystemConfig.get_grpc_max_message_bytes()
    assert Application.get_env(:grpc, :max_message_length) == original
    assert render(view) =~ "Restart each Engine node"

    {:ok, reloaded, _html} = live(conn, ~p"/bo/system-config?tab=global")
    assert has_element?(reloaded, "#global-grpc-limit-input[value='8']")
  end

  test "invalid submissions retain the previous setting and display validation feedback", %{
    conn: conn
  } do
    assert :ok = SystemConfig.set_grpc_max_message_mib("32")
    {:ok, view, _html} = live(conn, ~p"/bo/system-config?tab=global")

    for value <- ["0", "-1", "1.5", "4096", ""] do
      html =
        view
        |> form("#global-grpc-limit-form", grpc_max_message_mib: value)
        |> render_submit()

      assert html =~ "Enter a whole number from 1 to 4095 MiB"
      assert {:ok, 33_554_432} = SystemConfig.get_grpc_max_message_bytes()
    end
  end

  test "a corrupt stored setting is visible and can be repaired rather than shown as the default",
       %{conn: conn} do
    {:ok, _} = SystemConfig.set_config("system.global.grpc_max_message_bytes", "broken")
    {:ok, view, html} = live(conn, ~p"/bo/system-config?tab=global")
    assert html =~ "Stored gRPC message size is invalid"
    refute has_element?(view, "#global-grpc-limit-input[value='64']")

    view
    |> form("#global-grpc-limit-form", grpc_max_message_mib: "64")
    |> render_submit()

    assert {:ok, 67_108_864} = SystemConfig.get_grpc_max_message_bytes()
    refute render(view) =~ "Stored gRPC message size is invalid"
  end
end
