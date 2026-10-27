defmodule ZaqWeb.Live.BO.Communication.WebWidgetLiveCoverageTest do
  use ZaqWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Mox
  import Zaq.AccountsFixtures

  alias Phoenix.Component
  alias Zaq.Channels.WebBridge
  alias Zaq.Engine.ChannelConfig
  alias Zaq.Repo
  alias ZaqWeb.Live.BO.Communication.AgentRoutingOptions
  alias ZaqWeb.Live.BO.Communication.WebWidgetLive

  defmodule Adapter do
    @behaviour Zaq.Channels.WebBridge

    @impl true
    def build_runtime_specs(config, _hooks),
      do:
        {:ok,
         {%{id: :widget_coverage, start: {Agent, :start_link, [fn -> config.token end]}}, []}}

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
           summary: "Ready",
           verification: %{scope: :local, session_handshake: :verified},
           effective_settings: Zaq.WidgetReadinessFixtures.response().effective_settings
         }}
  end

  defmodule FailingInstallationAdapter do
    defdelegate build_runtime_specs(config, hooks), to: Adapter
    def installation(_config, _base_url, scope: "/channels"), do: {:error, :unavailable}
  end

  defmodule FailingRuntimeAdapter do
    def build_runtime_specs(_config, _hooks), do: {:error, :runtime_unavailable}
    def installation(config, base_url, opts), do: Adapter.installation(config, base_url, opts)
  end

  defmodule FailingArchiveBridge do
    def stop_runtime(_config), do: {:error, :offline}
  end

  setup %{conn: conn} do
    stub(Zaq.NodeRouterMock, :find_node, fn _supervisor -> :channels@localhost end)
    user = admin_fixture(%{must_change_password: false})
    channels = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :web_widget, %{bridge: WebBridge, adapter: Adapter})
    )

    on_exit(fn -> Application.put_env(:zaq, :channels, channels) end)
    %{conn: init_test_session(conn, %{user_id: user.id})}
  end

  test "missing installation and archive targets report unavailable configuration", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")

    render_click(view, "open_installation", %{"id" => "unknown"})
    assert render(view) =~ "Configuration not found or archived"
    refute has_element?(view, "#widget-installation-modal")

    render_click(view, "archive", %{})
    assert render(view) =~ "Configuration not found or archived"
    render_click(view, "archive", %{"id" => "unknown"})
    assert render(view) =~ "Configuration not found or archived"
    assert ChannelConfig.list_by_provider("web_widget") == []
  end

  test "second key generation preserves the existing key", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Key coverage")
    view |> element("#generate-widget-key") |> render_click()
    key = Repo.get_by!(ChannelConfig, name: "Key coverage").token
    render_click(view, "generate_key", %{})
    assert render(view) =~ "A key already exists. Use Rotate authentication key."
    refute has_element?(view, "#new-widget-key")
    assert Repo.get_by!(ChannelConfig, name: "Key coverage").token == key
  end

  test "archive rejects a stale displayed connector and leaves it intact", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Stale archive")
    config = Repo.get_by!(ChannelConfig, name: "Stale archive")
    view |> element("#close-widget-modal") |> render_click()
    config |> Ecto.Changeset.change(name: "Changed elsewhere") |> Repo.update!()

    render_click(view, "archive", %{"id" => to_string(config.id)})
    assert has_element?(view, "#widget-recovery-error", "changed elsewhere")
    assert is_nil(Repo.get!(ChannelConfig, config.id).archived_at)
  end

  test "archive failure refreshes persisted state and another click completes deletion", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Archive failure")
    config = Repo.get_by!(ChannelConfig, name: "Archive failure")
    view |> element("#close-widget-modal") |> render_click()
    config |> Ecto.Changeset.change(enabled: true) |> Repo.update!()

    channels = Application.fetch_env!(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      put_in(channels, [:web_widget, :bridge], FailingArchiveBridge)
    )

    # Refresh the displayed revision after enabling the connector.
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#archive-widget-#{config.id}") |> render_click()

    assert %ChannelConfig{enabled: false, archived_at: nil} = Repo.get!(ChannelConfig, config.id)
    assert has_element?(view, "#widget-connector-#{config.id}", "Disabled")
    assert render(view) =~ "The operation is unavailable."
    refute render(view) =~ "Retry Delete"
    refute render(view) =~ "runtime_pending"

    Application.put_env(:zaq, :channels, channels)
    view |> element("#archive-widget-#{config.id}") |> render_click()

    assert Repo.get!(ChannelConfig, config.id).archived_at
    refute has_element?(view, "#widget-connector-#{config.id}")
    assert render(view) =~ "Configuration archived."
  end

  test "non-string allowed domains are rejected without persistence", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()

    render_submit(view, "save", %{
      "widget" => %{"name" => "Invalid domain type", "allowed_domains" => ["*"]}
    })

    assert has_element?(view, "#widget-allowed-domains-field .zaq-field-error")
    assert ChannelConfig.list_by_provider("web_widget") == []
  end

  test "async status failure marks every widget unknown and schedules refresh" do
    first = %ChannelConfig{id: 101, enabled: true}
    second = %ChannelConfig{id: 202, enabled: false}

    socket =
      %Phoenix.LiveView.Socket{}
      |> Component.assign(:configs, [first, second])
      |> Component.assign(:health_timer, nil)

    assert {:noreply, result} =
             WebWidgetLive.handle_async(:widget_statuses, {:exit, :simulated_failure}, socket)

    timer = result.assigns.health_timer

    try do
      assert result.assigns.ingress_statuses == %{
               101 => %{status: :unknown, summary: "Widget readiness cannot be verified"},
               202 => %{status: :unknown, summary: "Widget readiness cannot be verified"}
             }

      assert is_reference(timer)
    after
      if is_reference(timer), do: Process.cancel_timer(timer)
    end
  end

  test "unknown selection preserves the current connector and invalid agent is rejected", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Selection remains")
    config = Repo.get_by!(ChannelConfig, name: "Selection remains")

    render_click(view, "select_connector", %{"id" => "unknown"})
    assert render(view) =~ "Configuration not found or archived"
    assert has_element?(view, "input[name='widget[name]'][value='Selection remains']")

    key =
      AgentRoutingOptions.rule_key(%{channel_config_id: config.id})

    view
    |> element("#widget-config-form")
    |> render_submit(%{
      "widget" => %{
        "name" => config.name,
        "allowed_domains" => "https://parent.example.test",
        "rules" => %{key => %{"channel_config_id" => to_string(config.id), "choice" => "999999"}}
      }
    })

    assert render(view) =~ "Choose a conversation-enabled agent"
    assert Repo.get!(ChannelConfig, config.id).name == "Selection remains"
  end

  test "disabled status and missing-base installation message are visible", %{conn: conn} do
    assert :ok = Zaq.System.set_global_base_url(nil)
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Disabled installation")
    config = Repo.get_by!(ChannelConfig, name: "Disabled installation")
    assert has_element?(view, "#widget-connector-#{config.id}", "Disabled")

    render_click(view, "open_installation", %{"id" => to_string(config.id)})
    assert has_element?(view, "#widget-installation-modal", "Configure the global base URL")
  end

  test "adapter installation failure renders the unavailable-script message", %{conn: conn} do
    channels = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :web_widget, %{bridge: WebBridge, adapter: FailingInstallationAdapter})
    )

    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Installation failure")
    config = Repo.get_by!(ChannelConfig, name: "Installation failure")

    render_click(view, "open_installation", %{"id" => to_string(config.id)})

    assert has_element?(
             view,
             "#widget-installation-modal",
             "The adapter's installation script is unavailable."
           )
  end

  test "runtime synchronization failure warns after the configuration is persisted", %{conn: conn} do
    channels = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :web_widget, %{bridge: WebBridge, adapter: FailingRuntimeAdapter})
    )

    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Runtime failure")
    config = Repo.get_by!(ChannelConfig, name: "Runtime failure")

    view
    |> element("#widget-config-form")
    |> render_submit(%{"widget" => %{"name" => "Runtime failure updated", "enabled" => "true"}})

    assert Repo.get!(ChannelConfig, config.id).name == "Runtime failure updated"
    assert has_element?(view, "#widget-recovery-error", "runtime synchronization failed")
  end

  test "policy hints show effective values when verified and legacy guidance when unknown", %{
    conn: conn
  } do
    channels = Application.get_env(:zaq, :channels)

    Application.put_env(
      :zaq,
      :channels,
      Map.put(channels, :web_widget, %{bridge: WebBridge, adapter: ReadyAdapter})
    )

    assert :ok = Zaq.System.set_global_base_url("https://zaq.example.test")
    {:ok, view, _} = live(conn, ~p"/bo/channels/retrieval/web_widget")
    view |> element("#new-widget-config") |> render_click()
    create(view, "Policy coverage")
    config = Repo.get_by!(ChannelConfig, name: "Policy coverage")
    on_exit(fn -> WebBridge.stop_runtime(%{id: config.id, provider: "web_widget"}) end)
    assert render(view) =~ "Effective value is unverified"
    view |> element("#toggle-widget-#{config.id}") |> render_click()
    render_async(view, 5_000)
    view |> element("#edit-widget-#{config.id}") |> render_click()
    render_async(view, 5_000)
    assert render(view) =~ "Effective: zaq_issuer (connector)"
  end

  defp create(view, name) do
    view
    |> element("#widget-config-form")
    |> render_submit(%{
      "widget" => %{
        "name" => name,
        "allowed_domains" => "https://parent.example.test",
        "enabled" => "false"
      }
    })
  end
end
