defmodule ZaqWeb.Live.BO.Communication.WebWidgetLiveTest do
  use ZaqWeb.ConnCase

  import Phoenix.LiveViewTest
  import Mox
  import Zaq.AccountsFixtures

  alias Zaq.Agent.ConfiguredAgent
  alias Zaq.Channels.Supervisor, as: ChannelsSupervisor
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.{ChannelConfig, IncomingMessageRouting}
  alias Zaq.Repo
  alias Zaq.SystemConfigFixtures
  alias ZaqWeb.Live.BO.Communication.AgentRoutingOptions

  defmodule Adapter do
    @behaviour Zaq.Channels.WebBridge

    @impl true
    def build_runtime_specs(config, _hooks),
      do: {:ok, {%{id: :widget, start: {Agent, :start_link, [fn -> config.token end]}}, []}}

    @impl true
    def installation(%{id: id}, base_url, scope: "/channels"),
      do: {:ok, "<script src=\"#{base_url}/widget.js\" data-widget-id=\"#{id}\"></script>"}
  end

  defmodule ReadyAdapter do
    defdelegate build_runtime_specs(config, hooks), to: Adapter
    defdelegate installation(config, base_url, opts), to: Adapter

    def ingress_status(_config, timeout_ms: 2_000),
      do:
        {:ok,
         %{
           status: :ok,
           summary: "Ready locally; external HTTPS not checked",
           mode: "websocket",
           verification: %{
             scope: :local,
             session_handshake: :verified,
             external_https: :not_checked
           },
           effective_settings: Zaq.WidgetReadinessFixtures.response().effective_settings
         }}
  end

  setup %{conn: conn} do
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)
    user = admin_fixture(%{must_change_password: false})
    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "mounts the real form and allows disabled configuration before prerequisites", %{
    conn: conn
  } do
    configure_adapter(nil)
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
    assert has_element?(view, "#widget-connector-#{config.id}", "Widget ID: #{config.id}")
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

  test "widget edit modal reuses streamed-update controls and retains unsaved ordinary edits",
       %{
         conn: conn
       } do
    configure_adapter(nil)
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    refute has_element?(view, "[id^='stream-updates-']")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Stream settings widget")
    config = Repo.get_by!(ChannelConfig, name: "Stream settings widget")
    previous = config.settings
    selector = "#stream-updates-#{config.id}"
    assert has_element?(view, "#widget-config-modal #{selector}")
    assert has_element?(view, "#widget-config-form #{selector}")

    view
    |> form("#widget-config-form", widget: %{"name" => "Unsaved widget name"})
    |> render_change()

    view
    |> form("#widget-config-form",
      live_updates: %{"throttle_enabled" => "false", "triggers" => %{"reasoning" => "false"}}
    )
    |> render_change()

    assert Repo.get!(ChannelConfig, config.id).settings == previous
    assert Repo.get!(ChannelConfig, config.id).name == config.name
    refute has_element?(view, "button", "Save streamed updates")

    assert render(view) =~
             "When off, selected events can trigger updates without a minimum time interval."

    view |> form("#widget-config-form") |> render_submit()

    saved = Repo.get!(ChannelConfig, config.id)
    assert Map.delete(saved.settings, "live_updates") == previous
    refute saved.settings["live_updates"]["throttle_enabled"]
    refute saved.settings["live_updates"]["triggers"]["reasoning"]
    refute saved.enabled
    assert render(view) =~ "Progress/status messages are unaffected"
    assert Repo.get!(ChannelConfig, config.id).name == "Unsaved widget name"

    assert Repo.get!(ChannelConfig, config.id).settings["live_updates"] ==
             saved.settings["live_updates"]
  end

  test "streamed settings in an old widget edit modal cannot overwrite a newer connector", %{
    conn: conn
  } do
    configure_adapter(nil)
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Stale stream settings widget")
    config = Repo.get_by!(ChannelConfig, name: "Stale stream settings widget")
    Repo.update!(Ecto.Changeset.change(config, name: "Changed elsewhere"))

    view
    |> form("#widget-config-form", live_updates: %{"enabled" => "false"})
    |> render_submit()

    assert render(view) =~ "Configuration changed elsewhere"
    assert Repo.get!(ChannelConfig, config.id).name == "Changed elsewhere"
    refute Map.has_key?(Repo.get!(ChannelConfig, config.id).settings, "live_updates")
  end

  test "widget Cancel discards streamed preferences and ordinary fields", %{conn: conn} do
    configure_adapter(nil)
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Cancel settings")
    config = Repo.get_by!(ChannelConfig, name: "Cancel settings")

    view
    |> form("#widget-config-form",
      widget: %{"name" => "Discarded"},
      live_updates: %{"enabled" => "false"}
    )
    |> render_change()

    view |> element("#close-widget-modal") |> render_click()
    view |> element("#edit-widget-#{config.id}") |> render_click()
    assert has_element?(view, "#widget_name[value='Cancel settings']")
    assert has_element?(view, "input[name='live_updates[enabled]'][type='checkbox'][checked]")
    refute Map.has_key?(Repo.get!(ChannelConfig, config.id).settings, "live_updates")
  end

  test "widget invalid interval keeps both settings unchanged and permits correction", %{
    conn: conn
  } do
    configure_adapter(nil)
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Atomic widget")
    config = Repo.get_by!(ChannelConfig, name: "Atomic widget")

    view
    |> form("#widget-config-form",
      widget: %{"name" => "Edited widget"},
      live_updates: %{"min_interval_ms" => "0"}
    )
    |> render_submit()

    assert render(view) =~ "must be a positive integer"
    assert Repo.get!(ChannelConfig, config.id).name == config.name
    assert Repo.get!(ChannelConfig, config.id).settings == config.settings

    view
    |> form("#widget-config-form", live_updates: %{"min_interval_ms" => "350"})
    |> render_submit()

    assert Repo.get!(ChannelConfig, config.id).name == "Edited widget"
    assert Repo.get!(ChannelConfig, config.id).settings["live_updates"]["min_interval_ms"] == 350
  end

  test "key is revealed once, dismissal and connector switching remove it", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Support")
    view |> element("#generate-widget-key") |> render_click()
    assert has_element?(view, "#new-widget-key")
    assert has_element?(view, "#rotate-widget-key[data-confirm]")
    assert has_element?(view, "#widget-key-warning.zaq-warning")
    assert has_element?(view, "#widget-key-generated-at time[datetime]")
    refute render(view) =~ ~r/Last generated or rotated: .*T\d{2}:\d{2}/
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

    assert has_element?(
             view,
             "#widget-config-form .zaq-field-error",
             "Use 1–255 characters without leading or trailing spaces."
           )

    assert Repo.get!(ChannelConfig, config.id).settings == config.settings
    assert has_element?(view, "#widget-identity-issuer[value='']")
  end

  test "configuration validation uses the design-system field error", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()

    view
    |> form("#widget-config-form", widget: %{name: ""})
    |> render_submit()

    assert has_element?(view, "#widget-config-form .zaq-field-error", "can't be blank")
    refute render(view) =~ "name: can't be blank"
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
    send(list.pid, :refresh_ingress_statuses)
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
    configure_adapter(nil)
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

    assert has_element?(view, "#widget-connector-#{first.id} button[aria-current='true']")
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

    assert has_element?(
             view,
             "#widget-allowed-domains-field .zaq-field-error",
             "Enter an exact HTTP(S) origin"
           )

    assert ChannelConfig.list_by_provider("web_widget") == []

    view
    |> element("#widget-config-form")
    |> render_change(%{
      "widget" => %{"allowed_domains" => "https://parent.example.test/"},
      "_target" => ["widget", "allowed_domains"]
    })

    assert has_element?(
             view,
             "#widget-allowed-domains-field .zaq-field-error",
             "Remove the trailing slash: use https://parent.example.test."
           )

    view
    |> element("#widget-config-form")
    |> render_change(%{
      "widget" => %{"allowed_domains" => "https://parent.example.test"},
      "_target" => ["widget", "allowed_domains"]
    })

    refute has_element?(view, "#widget-allowed-domains-field .zaq-field-error")
    view |> render_submit("save", %{"widget" => %{"name" => "Forged", "token" => "chosen"}})
    assert render(view) =~ "Invalid configuration request"
    assert ChannelConfig.list_by_provider("web_widget") == []
  end

  test "modal uses field hints, places enablement last and omits duplicate widget identity", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Layout widget")
    config = Repo.get_by!(ChannelConfig, name: "Layout widget")

    refute has_element?(view, "#widget-id")
    refute has_element?(view, "#copy-widget-id")
    assert has_element?(view, "#widget-agent-hint.zaq-field-hint")
    assert has_element?(view, "#widget-same-site-hint.zaq-field-hint")
    assert has_element?(view, "#generate-widget-key[aria-label='Generate authentication key']")
    assert has_element?(view, "#widget-key-control-row #widget-key-status")
    assert has_element?(view, "#widget-key-control-row #generate-widget-key")
    refute has_element?(view, "#widget-key-control-row #widget-key-hint")
    assert has_element?(view, "#widget-key-hint.zaq-field-hint")
    refute has_element?(view, "#archive-widget-config")

    html = render(view)
    assert index_of!(html, "id=\"widget-enabled\"") > index_of!(html, "id=\"widget-key-status\"")
    view |> element("#close-widget-modal") |> render_click()
    assert has_element?(view, "#archive-widget-#{config.id}[aria-label='Archive configuration']")
    assert has_element?(view, "#archive-widget-#{config.id} [class*='hero-trash']")
  end

  test "banner archive targets its own connector and never the last edited connector", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Archive first")
    first = Repo.get_by!(ChannelConfig, name: "Archive first")
    view |> element("#close-widget-modal") |> render_click()
    view |> element("#new-widget-config") |> render_click()
    create(view, "Keep second")
    second = Repo.get_by!(ChannelConfig, name: "Keep second")
    view |> element("#close-widget-modal") |> render_click()

    view |> element("#archive-widget-#{first.id}") |> render_click()
    assert Repo.get!(ChannelConfig, first.id).archived_at
    refute Repo.get!(ChannelConfig, second.id).archived_at
    refute has_element?(view, "#widget-connector-#{first.id}")
    assert has_element?(view, "#widget-connector-#{second.id}")
  end

  test "shared routing fields preserve inheritance and NONE within the selected widget", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    create(view, "Shared first")
    first = Repo.get_by!(ChannelConfig, name: "Shared first")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Shared second", "__none__")
    second = Repo.get_by!(ChannelConfig, name: "Shared second")
    view |> element("#edit-widget-#{first.id}") |> render_click()

    key =
      AgentRoutingOptions.rule_key(%{channel_config_id: first.id})

    assert has_element?(view, "#widget-agent input[name='widget[rules][#{key}][choice]']")

    assert has_element?(
             view,
             "input[name='widget[rules][#{key}][channel_config_id]'][value='#{first.id}']"
           )

    assert has_element?(view, "label[for='widget-agent-trigger']", "Default agent")
    assert has_element?(view, "#widget-agent", "Use inherited routing")

    view
    |> element("#widget-config-form")
    |> render_submit(%{
      "widget" => %{
        "rules" => %{key => %{"channel_config_id" => to_string(first.id), "choice" => "__none__"}}
      }
    })

    assert IncomingMessageRouting.get_rule(%{channel_config_id: first.id}).routing_mode == :none

    view
    |> element("#widget-config-form")
    |> render_submit(%{
      "widget" => %{
        "rules" => %{key => %{"channel_config_id" => to_string(first.id), "choice" => ""}}
      }
    })

    assert IncomingMessageRouting.get_rule(%{channel_config_id: first.id}) == nil
    assert IncomingMessageRouting.get_rule(%{channel_config_id: second.id}).routing_mode == :none

    render_submit(view, "save", %{
      "widget" => %{
        "name" => "Forged scope",
        "rules" => %{
          key => %{"channel_config_id" => to_string(second.id), "choice" => ""}
        }
      }
    })

    assert render(view) =~ "Invalid configuration request"
    assert Repo.get!(ChannelConfig, first.id).name == "Shared first"
    assert IncomingMessageRouting.get_rule(%{channel_config_id: second.id}).routing_mode == :none
  end

  test "shared routing rejects extra scopes and ambiguous choices before persistence", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()

    for rules <- [
          %{"one" => %{"choice" => "__none__", "person_id" => "1"}},
          %{"one" => %{"choice" => "__none__", "topic_id" => "foreign"}},
          %{"one" => %{"choice" => "__none__"}, "two" => %{"choice" => ""}}
        ] do
      render_submit(view, "save", %{"widget" => %{"name" => "Invalid scope", "rules" => rules}})
      assert render(view) =~ "Invalid configuration request"
    end

    render_submit(view, "save", %{
      "widget" => %{
        "name" => "Ambiguous",
        "agent_id" => "",
        "rules" => %{"one" => %{"choice" => "__none__"}}
      }
    })

    assert render(view) =~ "Invalid configuration request"
    assert ChannelConfig.list_by_provider("web_widget") == []
  end

  test "shared routing keeps an explicit agent selection across validation, save and reopen", %{
    conn: conn
  } do
    credential = SystemConfigFixtures.ai_credential_fixture()

    agent =
      %ConfiguredAgent{}
      |> ConfiguredAgent.changeset(%{
        name: "Shared widget agent",
        job: "Answer questions",
        model: "gpt-4.1-mini",
        credential_id: credential.id,
        strategy: "react",
        conversation_enabled: true,
        active: true
      })
      |> Repo.insert!()

    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    key = AgentRoutingOptions.rule_key(%{})

    render_change(view, "validate", %{
      "widget" => %{"rules" => %{key => %{"choice" => to_string(agent.id)}}}
    })

    assert has_element?(view, "#widget-agent input[data-select-value][value='#{agent.id}']")
    create(view, "Shared agent", to_string(agent.id))
    config = Repo.get_by!(ChannelConfig, name: "Shared agent")
    rule = IncomingMessageRouting.get_rule(%{channel_config_id: config.id})
    assert rule.routing_mode == :agent
    assert rule.configured_agent_id == agent.id
    refute Map.has_key?(config.settings, "agent_id")
    view |> element("#close-widget-modal") |> render_click()
    view |> element("#edit-widget-#{config.id}") |> render_click()
    assert has_element?(view, "#widget-agent input[data-select-value][value='#{agent.id}']")
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
    refute has_element?(view, "#widget-installation-modal")
    view |> element("#widget-script-#{config.id}") |> render_click()
    assert has_element?(view, "#widget-installation-modal[role='dialog']")
    assert has_element?(view, "#widget-installation-modal", "Install Live widget on your website")
    assert has_element?(view, "#widget-install-script", "<script")
    refute has_element?(view, "script[src='https://zaq.example.test/widget.js']")
    assert render(view) =~ "&lt;script"
    assert has_element?(view, "#widget-install-script", "data-widget-id=\"#{config.id}\"")

    assert has_element?(
             view,
             "#widget-installation-required",
             "data-token-url"
           )

    assert has_element?(view, "#widget-installation-optional", "iframe-location-id")
    assert has_element?(view, "#widget-installation-optional", "stylesheet-url")
    assert has_element?(view, "#widget-installation-optional", "data-widget-url")
    assert has_element?(view, "#widget-token-response", "Cache-Control: no-store")
    view |> element("#close-widget-installation") |> render_click()
    refute has_element?(view, "#widget-installation-modal")
    view |> element("#widget-script-#{second.id}") |> render_click()
    assert has_element?(view, "#widget-install-script", "data-widget-id=\"#{second.id}\"")
    view |> element("#close-widget-installation") |> render_click()
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

    view |> element("#close-widget-modal") |> render_click()
    view |> element("#archive-widget-#{config.id}") |> render_click()
    assert Repo.get!(ChannelConfig, config.id).archived_at
    refute Process.alive?(reenabled)
    refute has_element?(view, "#new-widget-key")
  end

  defp create(view, name, agent_id \\ "") do
    unless has_element?(view, "#widget-config-form"),
      do: view |> element("#new-widget-config") |> render_click()

    key = AgentRoutingOptions.rule_key(%{})

    view
    |> element("#widget-config-form")
    |> render_submit(%{
      "widget" => %{
        "name" => name,
        "allowed_domains" => "https://parent.example.test",
        "enabled" => "false",
        "rules" => %{key => %{"choice" => agent_id}}
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

  defp index_of!(html, marker) do
    {index, _length} = :binary.match(html, marker)
    index
  end
end
