defmodule ZaqWeb.Live.BO.System.StudioConfigLiveTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Zaq.AccountsFixtures

  alias Zaq.Accounts
  alias Zaq.System.TelemetryConfig
  alias ZaqWeb.Live.BO.System.SystemConfig.TelemetryTab
  alias ZaqWeb.StudioRuntime

  setup %{conn: conn} do
    refute StudioRuntime.running?()
    user = admin_fixture()
    {:ok, user} = Accounts.change_password(user, %{password: "StrongPass1!"})
    user = Accounts.get_user(user.id)

    on_exit(fn ->
      Supervisor.terminate_child(JidoStudio.Supervisor, JidoStudio.Runtime)
      Supervisor.delete_child(JidoStudio.Supervisor, JidoStudio.Runtime)
      :telemetry.detach("jido-studio-trace-buffer")
    end)

    %{conn: init_test_session(conn, %{user_id: user.id}), user: user}
  end

  test "renders an off switch without a Studio link and does not start any Studio services", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/bo/system-config?tab=telemetry")
    assert has_element?(view, "#jido-studio-toggle[role=switch][aria-checked=false]")
    refute has_element?(view, "#jido-studio-toggle[disabled]")
    refute has_element?(view, "#open-jido-studio")
    refute Process.whereis(JidoStudio.Runtime)
    refute Process.whereis(JidoStudio.Persistence.ETS)
  end

  test "enabling Studio checks and disables the switch and reveals a secure new-tab link", %{
    conn: conn
  } do
    {:ok, view, _html} = live(conn, "/bo/system-config?tab=telemetry")
    view |> element("#jido-studio-toggle") |> render_click()

    assert StudioRuntime.running?()
    assert has_element?(view, "#jido-studio-toggle[disabled][aria-checked=true]")

    assert has_element?(
             view,
             "#open-jido-studio[href='/bo/studio'][target='_blank'][rel='noopener noreferrer']",
             "Open Studio"
           )

    assert render(view) =~ "Restart ZAQ to turn off"
    pid = Process.whereis(JidoStudio.Runtime)
    render_click(view, "start_jido_studio", %{})
    assert Process.whereis(JidoStudio.Runtime) == pid

    {:ok, refreshed, _html} = live(conn, "/bo/system-config?tab=telemetry")
    assert has_element?(refreshed, "#jido-studio-toggle[disabled][aria-checked=true]")
    assert has_element?(refreshed, "#open-jido-studio")
  end

  test "another open settings tab updates when Studio starts", %{conn: conn} do
    {:ok, first, _html} = live(conn, "/bo/system-config?tab=telemetry")
    {:ok, second, _html} = live(conn, "/bo/system-config?tab=telemetry")

    first |> element("#jido-studio-toggle") |> render_click()
    assert has_element?(second, "#jido-studio-toggle[disabled][aria-checked=true]")
    assert has_element?(second, "#open-jido-studio")
  end

  test "staff sees a disabled switch and cannot forge a start event", %{conn: conn} do
    staff = staff_fixture()
    {:ok, staff} = Accounts.change_password(staff, %{password: "StrongPass1!"})
    conn = init_test_session(conn, %{user_id: staff.id})
    {:ok, view, _html} = live(conn, "/bo/system-config?tab=telemetry")

    assert has_element?(view, "#jido-studio-toggle[disabled][aria-checked=false]")

    assert render_click(view, "start_jido_studio", %{}) =~
             "Only administrators can enable Jido Studio"

    refute StudioRuntime.running?()
    refute has_element?(view, "#open-jido-studio")
  end

  test "startup failure keeps Studio off, link hidden and allows retry", %{conn: conn} do
    start_supervised!(JidoStudio.TraceBuffer)
    {:ok, view, _html} = live(conn, "/bo/system-config?tab=telemetry")

    assert view |> element("#jido-studio-toggle") |> render_click() =~
             "Jido Studio could not be started"

    refute StudioRuntime.running?()
    assert has_element?(view, "#jido-studio-toggle[aria-checked=false]")
    refute has_element?(view, "#jido-studio-toggle[disabled]")
    refute has_element?(view, "#open-jido-studio")
  end

  test "saving telemetry settings does not implicitly enable Studio", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/bo/system-config?tab=telemetry")

    html =
      view
      |> form("#telemetry-config-form", telemetry_config: %{request_duration_threshold_ms: "42"})
      |> render_submit()

    assert html =~ "Telemetry settings saved"
    assert Zaq.System.get_telemetry_config().request_duration_threshold_ms == 42
    refute StudioRuntime.running?()
  end

  test "component hides the running Studio link from non-admins" do
    form = Phoenix.Component.to_form(TelemetryConfig.changeset(%TelemetryConfig{}, %{}))

    html =
      render_component(&TelemetryTab.panel/1,
        form: form,
        studio_running: true,
        studio_can_start: false
      )

    assert html =~ "Restart ZAQ to turn off"
    refute html =~ "Open Studio"
  end
end
