defmodule ZaqWeb.Plugs.StudioGuardTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias ZaqWeb.Live.BO.StudioGuard
  alias ZaqWeb.StudioRuntime

  setup do
    refute StudioRuntime.running?()
    user = admin_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    user = Accounts.get_user(user.id)

    on_exit(fn ->
      Supervisor.terminate_child(JidoStudio.Supervisor, JidoStudio.Runtime)
      Supervisor.delete_child(JidoStudio.Supervisor, JidoStudio.Runtime)
      :telemetry.detach("jido-studio-trace-buffer")
    end)

    %{user: user}
  end

  test "direct Studio routes redirect while stopped without starting persistence", %{
    conn: conn,
    user: user
  } do
    for path <- ["/bo/studio", "/bo/studio/traces"] do
      response = conn |> init_test_session(%{user_id: user.id}) |> get(path)
      assert redirected_to(response) == "/bo/system-config?tab=telemetry"
    end

    refute StudioRuntime.running?()
    refute Process.whereis(JidoStudio.Persistence.ETS)
  end

  test "unauthenticated requests still require BO login", %{conn: conn} do
    assert conn |> get("/bo/studio") |> redirected_to() == "/bo/login"
  end

  test "staff cannot access Studio even when it is running", %{conn: conn, user: user} do
    assert :ok = StudioRuntime.start(user)
    staff = staff_fixture()
    {:ok, staff} = Accounts.change_password(staff, %{password: "StrongPass1!"})
    response = conn |> init_test_session(%{user_id: staff.id}) |> get("/bo/studio")
    assert redirected_to(response) == "/bo/system-config?tab=telemetry"
  end

  test "pending password changes cannot access Studio", %{conn: conn} do
    user = admin_fixture()
    response = conn |> init_test_session(%{user_id: user.id}) |> get("/bo/studio")
    assert redirected_to(response) == "/bo/change-password"
  end

  test "on_mount halts websocket mounts while stopped", %{user: user} do
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: user}}
    assert {:halt, socket} = StudioGuard.on_mount(:require_running, %{}, %{}, socket)
    assert socket.redirected == {:redirect, %{status: 302, to: "/bo/system-config?tab=telemetry"}}
    refute Process.whereis(JidoStudio.Persistence.ETS)
  end

  test "admin can mount a connected Studio page after enabling it", %{conn: conn, user: user} do
    assert :ok = StudioRuntime.start(user)
    conn = init_test_session(conn, %{user_id: user.id})
    assert {:ok, _view, html} = live(conn, "/bo/studio/about")
    assert html =~ "Jido Studio"
  end
end
