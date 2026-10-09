defmodule ZaqWeb.Live.BO.Communication.WebWidgetLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mox
  import Zaq.AccountsFixtures

  alias Zaq.Channels.Supervisor, as: ChannelsSupervisor
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
  alias Zaq.Repo

  defmodule Adapter do
    @behaviour Zaq.Channels.Web.WidgetAdapter

    @impl true
    def build(config, _hooks),
      do: {:ok, {%{id: :widget, start: {Agent, :start_link, [fn -> config.token end]}}, []}}

    @impl true
    def embed_script(id, base_url),
      do: {:ok, "<script src=\"#{base_url}/widget.js\" data-widget-id=\"#{id}\"></script>"}
  end

  defmodule ReadyAdapter do
    defdelegate build(config, hooks), to: Adapter
    defdelegate embed_script(id, base_url), to: Adapter
    def status(_id, timeout_ms: 2_000), do: {:ok, Zaq.WidgetReadinessFixtures.response()}
  end

  setup %{conn: conn} do
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)
    user = admin_fixture(%{must_change_password: false})
    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "mounts the real form and allows disabled configuration before prerequisites", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    refute has_element?(view, "#widget-config-form")

    assert has_element?(
             view,
             "#widget-breadcrumb a[href='/bo/channels/retrieval']",
             "Communication"
           )

    refute has_element?(view, "[phx-click='refresh']")
    refute has_element?(view, "#widget-runtime-status")
    refute has_element?(view, "#widget-base-url-error")
    refute has_element?(view, "#widget-adapter-error")
    assert has_element?(view, ".hero-globe-alt")
    view |> element("#new-widget-config") |> render_click()
    assert has_element?(view, "#widget-config-form")
    assert has_element?(view, "#widget-config-modal #widget-config-form")

    assert has_element?(
             view,
             "#widget-config-modal #widget-base-url-error",
             "Global base URL is missing"
           )

    assert has_element?(
             view,
             "#widget-config-modal a[href='/bo/system-config']",
             "System Configuration"
           )

    assert has_element?(
             view,
             "#widget-config-modal #widget-adapter-error",
             "Web Widget adapter is not configured"
           )

    assert has_element?(view, "#widget-config-modal #generate-widget-key[disabled]")
    refute has_element?(view, "input[name='widget[display_name]']")
    assert has_element?(view, "#widget-enabled[disabled]")
    create(view, "Support")
    config = Repo.get_by!(ChannelConfig, name: "Support")
    refute config.enabled
    assert has_element?(view, "#widget-id[value='#{config.id}']")
    assert has_element?(view, "#generate-widget-key")
    assert has_element?(view, "#widget-script-#{config.id}[disabled]")
    view |> element("#close-widget-modal") |> render_click()
    refute has_element?(view, "#widget-base-url-error")
    refute has_element?(view, "#widget-adapter-error")
    assert has_element?(view, "#toggle-widget-#{config.id}[disabled]", "Enable")
    render_click(view, "toggle_enabled", %{"id" => to_string(config.id)})
    assert render(view) =~ "Configure the global base URL"
    refute Repo.get!(ChannelConfig, config.id).enabled
  end

  test "key is revealed once, dismissal and connector switching remove it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Support")
    view |> element("#generate-widget-key") |> render_click()
    assert has_element?(view, "#new-widget-key")
    assert has_element?(view, "#rotate-widget-key[data-confirm]")
    view |> element("#dismiss-widget-key") |> render_click()
    refute has_element?(view, "#new-widget-key")
    view |> element("#rotate-widget-key") |> render_click()
    assert has_element?(view, "#new-widget-key")
    view |> element("#close-widget-modal") |> render_click()
    refute has_element?(view, "#widget-config-form")
    refute has_element?(view, "#new-widget-key")
    config = Repo.get_by!(ChannelConfig, name: "Support")
    view |> element("#edit-widget-#{config.id}") |> render_click()
    refute has_element?(view, "#new-widget-key")
    view |> element("#new-widget-config") |> render_click()
    refute has_element?(view, "#new-widget-key")
  end

  test "JWT and SameSite fields default, save, reopen and reject invalid settings", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    assert has_element?(view, "#widget-identity-issuer[value='zaq_issuer']")
    assert has_element?(view, "#widget-identity-audience[value='zaq_audience']")
    assert has_element?(view, "#widget-same-site input[name='widget[same_site]'][value='None']")

    render_change(view, "validate", %{
      "widget" => %{"same_site" => "Strict"},
      "_target" => ["widget", "same_site"]
    })

    view
    |> form("#widget-config-form",
      widget: %{
        name: "Configured claims",
        identity_issuer: "parent_backend",
        identity_audience: "support_widget",
        same_site: "Strict"
      }
    )
    |> render_submit()

    config = Repo.get_by!(ChannelConfig, name: "Configured claims")
    assert config.settings["identity_issuer"] == "parent_backend"
    assert config.settings["identity_audience"] == "support_widget"
    assert config.settings["same_site"] == "Strict"
    view |> element("#close-widget-modal") |> render_click()
    view |> element("#edit-widget-#{config.id}") |> render_click()
    assert has_element?(view, "#widget-identity-issuer[value='parent_backend']")
    assert has_element?(view, "#widget-same-site input[name='widget[same_site]'][value='Strict']")

    view |> form("#widget-config-form", widget: %{identity_issuer: ""}) |> render_submit()
    assert render(view) =~ "invalid widget settings"
    assert Repo.get!(ChannelConfig, config.id).settings == config.settings
    assert has_element?(view, "#widget-identity-issuer[value='']")
  end

  test "legacy settings remain unset when the form is submitted unchanged", %{conn: conn} do
    config =
      %ChannelConfig{}
      |> ChannelConfig.changeset(%{
        name: "Legacy policy",
        provider: "web_widget",
        kind: "retrieval",
        enabled: false,
        settings: %{}
      })
      |> Repo.insert!()

    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#edit-widget-#{config.id}") |> render_click()
    assert has_element?(view, "#widget-same-site input[name='widget[same_site]'][value='']")
    assert has_element?(view, "#widget-same-site-trigger", "Preserve existing")
    view |> form("#widget-config-form", widget: %{name: "Legacy renamed"}) |> render_submit()
    assert Repo.get!(ChannelConfig, config.id).settings == %{"allowed_domains" => []}
  end

  test "enabled widgets without readiness support show Unknown on both surfaces", %{conn: conn} do
    configure_adapter()
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Unknown readiness")
    config = Repo.get_by!(ChannelConfig, name: "Unknown readiness")
    on_exit(fn -> WebBridge.stop_runtime(%{id: config.id, provider: "web_widget"}) end)
    view |> element("#toggle-widget-#{config.id}") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "#widget-health-#{config.id}", "Unknown")
    assert has_element?(view, "#widget-connector-#{config.id}", "Enabled")
    refute has_element?(view, "#widget-connector-#{config.id}", "Active")

    {:ok, list, _} = live(conn, ~p"/bo/channels/retrieval")
    render_async(list, 5_000)
    list |> element("#ingress-status-dot-web_widget") |> render_click()

    assert has_element?(
             list,
             "#ingress-status-modal",
             "Adapter does not support readiness checks"
           )
  end

  test "live health refresh preserves edits and agrees with the Channels list", %{conn: conn} do
    configure_adapter(ReadyAdapter)
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Ready widget")
    config = Repo.get_by!(ChannelConfig, name: "Ready widget")
    on_exit(fn -> WebBridge.stop_runtime(%{id: config.id, provider: "web_widget"}) end)
    view |> element("#toggle-widget-#{config.id}") |> render_click()
    render_async(view, 5_000)
    assert has_element?(view, "#widget-health-#{config.id}", "Ready")

    {:ok, list, _} = live(conn, ~p"/bo/channels/retrieval")
    render_async(list, 5_000)
    assert has_element?(list, "#ingress-status-dot-web_widget .status-success")

    view |> element("#edit-widget-#{config.id}") |> render_click()

    view
    |> form("#widget-config-form", widget: %{identity_issuer: "unsaved_parent"})
    |> render_change()

    channels = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :web_widget, %{bridge: WebBridge, adapter: Adapter})
    )

    send(view.pid, :refresh_widget_statuses)
    send(list.pid, :refresh_widget_ingress_statuses)
    render_async(view, 5_000)
    render_async(list, 5_000)
    assert has_element?(view, "#widget-health-#{config.id}", "Unknown")
    assert has_element?(view, "#widget-identity-issuer[value='unsaved_parent']")
    assert Repo.get!(ChannelConfig, config.id).settings["identity_issuer"] == "zaq_issuer"
    assert has_element?(list, "#ingress-status-dot-web_widget .status-neutral")

    view |> element("#toggle-widget-#{config.id}") |> render_click()
    render_async(view, 5_000)
    refute has_element?(view, "#widget-health-#{config.id}")
    assert has_element?(view, "#widget-connector-#{config.id}", "Disabled")
  end

  test "configured base URL leaves only the missing adapter error in the modal", %{conn: conn} do
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    refute has_element?(view, "#widget-prerequisite-errors")
    view |> element("#new-widget-config") |> render_click()
    refute has_element?(view, "#widget-base-url-error")
    assert has_element?(view, "#widget-adapter-error")
    create(view, "Missing adapter")
    config = Repo.get_by!(ChannelConfig, name: "Missing adapter")
    view |> element("#close-widget-modal") |> render_click()
    assert has_element?(view, "#toggle-widget-#{config.id}[disabled]", "Enable")
    render_click(view, "toggle_enabled", %{"id" => to_string(config.id)})
    assert render(view) =~ "Install and configure the widget adapter"
    refute Repo.get!(ChannelConfig, config.id).enabled
  end

  test "banner toggles only the target connector and allows disabling without prerequisites", %{
    conn: conn
  } do
    configure_adapter()
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "First toggle widget")
    first = Repo.get_by!(ChannelConfig, name: "First toggle widget")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Second toggle widget", "__none__")
    view |> element("#generate-widget-key") |> render_click()
    second = Repo.get_by!(ChannelConfig, name: "Second toggle widget")
    on_exit(fn -> WebBridge.stop_runtime(%{id: second.id, provider: "web_widget"}) end)
    view |> element("#close-widget-modal") |> render_click()
    view |> element("#toggle-widget-#{second.id}") |> render_click()

    assert has_element?(view, "#toggle-widget-#{second.id}", "Disable")
    refute has_element?(view, "#widget-config-modal")
    refute has_element?(view, "#new-widget-key")
    enabled = Repo.get!(ChannelConfig, second.id)
    assert enabled.enabled
    assert enabled.name == second.name
    assert enabled.settings == second.settings
    assert enabled.token == second.token
    assert IncomingMessageRouting.get_rule(%{channel_config_id: second.id}).routing_mode == :none
    refute Repo.get!(ChannelConfig, first.id).enabled
    assert {:ok, %{state_pid: pid}} = ChannelsSupervisor.lookup_runtime("web_widget_#{second.id}")

    assert :ok = Zaq.System.set_global_base_url(nil)
    channels = Application.get_env(:zaq, :channels)
    Application.put_env(:zaq, :channels, Map.put(channels, :web_widget, %{bridge: WebBridge}))
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    refute has_element?(view, "#toggle-widget-#{second.id}[disabled]")
    assert has_element?(view, "#toggle-widget-#{first.id}[disabled]")
    view |> element("#toggle-widget-#{second.id}") |> render_click()
    refute Repo.get!(ChannelConfig, second.id).enabled
    refute Process.alive?(pid)
  end

  test "banner rejects stale and unknown connector toggles without changing configuration", %{
    conn: conn
  } do
    configure_adapter()
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Toggle revision")
    config = Repo.get_by!(ChannelConfig, name: "Toggle revision")
    view |> element("#close-widget-modal") |> render_click()
    config |> Ecto.Changeset.change(name: "Changed elsewhere") |> Repo.update!()
    view |> element("#toggle-widget-#{config.id}") |> render_click()
    assert has_element?(view, "#widget-recovery-error", "changed elsewhere")
    refute Repo.get!(ChannelConfig, config.id).enabled
    view |> element("#reload-widget-config") |> render_click()
    assert has_element?(view, "#widget-connector-#{config.id}", "Changed elsewhere")
    refute has_element?(view, "#widget-recovery-error")
    render_click(view, "toggle_enabled", %{"id" => "unknown"})
    assert render(view) =~ "Configuration not found or archived"
    refute Repo.get!(ChannelConfig, config.id).enabled
  end

  test "multiple configs and IncomingMessageRouting choices remain isolated", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "First")
    first = Repo.get_by!(ChannelConfig, name: "First")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Second", "__none__")
    second = Repo.get_by!(ChannelConfig, name: "Second")
    assert IncomingMessageRouting.get_rule(%{channel_config_id: second.id}).routing_mode == :none
    assert IncomingMessageRouting.get_rule(%{channel_config_id: first.id}) == nil

    view
    |> element("#edit-widget-#{first.id}")
    |> render_click()

    assert has_element?(view, "#widget-id[value='#{first.id}']")
    refute has_element?(view, "#new-widget-key")
  end

  test "invalid origin and forged configuration fields are rejected", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")

    view |> element("#new-widget-config") |> render_click()

    view
    |> element("#widget-config-form")
    |> render_submit(%{
      "widget" => %{
        "name" => "Bad",
        "enabled" => "false",
        "allowed_domains" => "*"
      }
    })

    assert render(view) =~ "invalid widget settings"
    assert ChannelConfig.list_by_provider("web_widget") == []
    view |> render_submit("save", %{"widget" => %{"name" => "Forged", "token" => "chosen"}})
    assert render(view) =~ "Invalid configuration request"
    assert ChannelConfig.list_by_provider("web_widget") == []
  end

  test "stale edits offer contextual reload instead of a permanent refresh", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Original")
    config = Repo.get_by!(ChannelConfig, name: "Original")
    config |> Ecto.Changeset.change(name: "Changed elsewhere") |> Repo.update!()

    view
    |> element("#widget-config-form")
    |> render_submit(%{"widget" => %{"name" => "Stale edit"}})

    assert has_element?(view, "#widget-recovery-error", "changed elsewhere")
    view |> element("#reload-widget-config") |> render_click()
    assert has_element?(view, "input[name='widget[name]'][value='Changed elsewhere']")
    refute has_element?(view, "#reload-widget-config")
  end

  test "adapter snippet is escaped and live rotation refreshes the server-only key", %{conn: conn} do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(previous, :web_widget, %{bridge: WebBridge, adapter: Adapter})
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
    {:ok, missing_base_view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    missing_base_view |> element("#new-widget-config") |> render_click()
    assert has_element?(missing_base_view, "#widget-base-url-error")
    refute has_element?(missing_base_view, "#widget-adapter-error")
    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")

    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Live widget")
    refute has_element?(view, "#widget-base-url-error")
    refute has_element?(view, "#widget-adapter-error")
    refute has_element?(view, "#widget-prerequisite-errors")
    config = Repo.get_by!(ChannelConfig, name: "Live widget")
    refute config.enabled
    on_exit(fn -> WebBridge.stop_runtime(%{id: config.id, provider: "web_widget"}) end)

    view |> element("#new-widget-config") |> render_click()
    create(view, "Second widget")
    second = Repo.get_by!(ChannelConfig, name: "Second widget")
    view |> element("#close-widget-modal") |> render_click()
    refute has_element?(view, "#widget-install-script")
    view |> element("#widget-script-#{config.id}") |> render_click()
    assert has_element?(view, "#widget-install-script", "<script")
    refute has_element?(view, "script[src='https://zaq.example.test/widget.js']")
    assert render(view) =~ "&lt;script"
    assert has_element?(view, "#widget-install-script", "data-widget-id=\"#{config.id}\"")
    view |> element("#widget-script-#{second.id}") |> render_click()
    refute has_element?(view, "#widget-installation-#{config.id}")

    assert has_element?(
             view,
             "#widget-installation-#{second.id} #widget-install-script",
             "data-widget-id=\"#{second.id}\""
           )

    view |> element("#widget-script-#{config.id}") |> render_click()
    view |> element("#widget-script-#{config.id}") |> render_click()
    refute has_element?(view, "#widget-install-script")
    view |> element("#edit-widget-#{config.id}") |> render_click()
    view |> element("#generate-widget-key") |> render_click()

    view |> element("#widget-config-form") |> render_submit(%{"widget" => %{"enabled" => "true"}})

    assert {:ok, %{state_pid: initial}} =
             ChannelsSupervisor.lookup_runtime("web_widget_#{config.id}")

    assert Agent.get(initial, & &1) == Repo.get!(ChannelConfig, config.id).token
    old_key = Agent.get(initial, & &1)
    view |> element("#rotate-widget-key") |> render_click()

    assert {:ok, %{state_pid: replacement}} =
             ChannelsSupervisor.lookup_runtime("web_widget_#{config.id}")

    refute initial == replacement
    refute Process.alive?(initial)
    refute Agent.get(replacement, & &1) == old_key
    assert Agent.get(replacement, & &1) == Repo.get!(ChannelConfig, config.id).token

    view
    |> element("#widget-config-form")
    |> render_submit(%{"widget" => %{"enabled" => "false"}})

    refute Process.alive?(replacement)
    refute Repo.get!(ChannelConfig, config.id).enabled
    refute has_element?(view, "#widget-runtime-status")
    view |> element("#widget-config-form") |> render_submit(%{"widget" => %{"enabled" => "true"}})

    assert {:ok, %{state_pid: reenabled}} =
             ChannelsSupervisor.lookup_runtime("web_widget_#{config.id}")

    view |> element("#archive-widget-config") |> render_click()
    assert Repo.get!(ChannelConfig, config.id).archived_at
    refute Process.alive?(reenabled)
    refute has_element?(view, "#new-widget-key")
  end

  defp create(view, name, agent_id \\ "") do
    unless has_element?(view, "#widget-config-form"),
      do: view |> element("#new-widget-config") |> render_click()

    view
    |> element("#widget-config-form")
    |> render_submit(%{
      "widget" => %{
        "name" => name,
        "allowed_domains" => "https://parent.example.test",
        "enabled" => "false",
        "agent_id" => agent_id
      }
    })
  end

  defp configure_adapter(adapter \\ Adapter) do
    previous = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(previous, :web_widget, %{bridge: WebBridge, adapter: adapter})
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, previous) end)
  end
end
