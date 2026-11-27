# lib/zaq_web/live/bo/dashboard_live.ex

defmodule ZaqWeb.Live.BO.DashboardLive do
  use ZaqWeb, :live_view

  import ZaqWeb.Dashboard.MetricOverview, only: [metric_overview: 1]
  import ZaqWeb.Dashboard.ServicesStatusTable, only: [services_status_table: 1]
  import ZaqWeb.Dashboard.ExtensionHealth, only: [extension_health: 1]
  import ZaqWeb.Components.DesignSystem.AddonUpsellCard, only: [addon_upsell_card: 1]

  alias Zaq.Addons.FeatureStore
  alias Zaq.Engine.Extension.Health
  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Contracts.DashboardChart
  alias Zaq.Event
  alias Zaq.NodeRouter

  @kpi_range "30d"
  @extension_refresh_ms 30_000
  @extension_read_timeout_ms 2_000

  @supervisor_map %{
    engine: Zaq.Engine.Supervisor,
    agent: Zaq.Agent.Supervisor,
    ingestion: Zaq.Ingestion.Supervisor,
    channels: Zaq.Channels.Supervisor,
    bo: ZaqWeb.Endpoint
  }

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Zaq.PubSub, "node:events")

    addon_data = FeatureStore.addon_data()
    telemetry_metrics = load_main_dashboard_metrics()

    days_left =
      case addon_data do
        nil ->
          nil

        data ->
          case DateTime.from_iso8601(data["expires_at"] || "") do
            {:ok, dt, _} -> DateTime.diff(dt, DateTime.utc_now(), :day)
            _ -> nil
          end
      end

    socket =
      assign(socket,
        current_path: "/bo/dashboard",
        addon_data: addon_data,
        days_left: days_left,
        services: refresh_services(),
        metric_cards: telemetry_metrics,
        extension_health: %Health{status: :checking},
        extension_health_request: nil,
        extension_health_timer: nil
      )

    {:ok, refresh_extension_health(socket)}
  end

  # -- Node event handlers --

  @impl true
  def handle_info({event, _node}, socket) when event in [:node_up, :node_down] do
    {:noreply, assign(socket, :services, refresh_services())}
  end

  @impl true
  def handle_info(:addons_updated, socket), do: {:noreply, socket}

  def handle_info(:refresh_extension_health, socket),
    do: {:noreply, refresh_extension_health(socket)}

  def handle_info(
        {:extension_health_timeout, ref},
        %{assigns: %{extension_health_request: ref}} = socket
      ) do
    socket = cancel_async(socket, :extension_health)
    {:noreply, finish_extension_health(socket, %Health{status: :unreachable, reason: :timeout})}
  end

  def handle_info({:extension_health_timeout, _ref}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(
        :extension_health,
        result,
        %{assigns: %{extension_health_request: ref}} = socket
      )
      when not is_nil(ref) do
    health =
      case result do
        {:ok, %Event{response: {:ok, %Health{} = health}}} -> health
        _ -> %Health{status: :unreachable, reason: :engine_unavailable}
      end

    {:noreply, finish_extension_health(socket, health)}
  end

  def handle_async(:extension_health, _result, socket), do: {:noreply, socket}

  # -- Private --

  defp refresh_extension_health(socket) do
    if connected?(socket) and is_nil(socket.assigns.extension_health_request) do
      event =
        Event.new(%{}, :engine,
          actor: %{user_id: socket.assigns.current_user.id},
          opts: [action: :extension_health, confidential: true]
        )

      ref = make_ref()

      timer =
        Process.send_after(self(), {:extension_health_timeout, ref}, @extension_read_timeout_ms)

      socket
      |> assign(extension_health_request: ref, extension_health_timer: timer)
      |> start_async(:extension_health, fn -> NodeRouter.dispatch(event) end)
    else
      socket
    end
  end

  defp finish_extension_health(socket, health) do
    if socket.assigns.extension_health_timer,
      do: Process.cancel_timer(socket.assigns.extension_health_timer)

    Process.send_after(self(), :refresh_extension_health, @extension_refresh_ms)

    assign(socket,
      extension_health: health,
      extension_health_request: nil,
      extension_health_timer: nil
    )
  end

  defp refresh_services do
    service_defs = [
      %{name: "Engine", role: :engine, description: "Sessions, ontology, API routing"},
      %{name: "Agent", role: :agent, description: "RAG, LLM, classifier"},
      %{name: "Ingestion", role: :ingestion, description: "Document processing, embeddings"},
      %{name: "Channels", role: :channels, description: "Mattermost, Slack, Email"},
      %{name: "Back Office", role: :bo, description: "Admin panel (LiveView)"}
    ]

    running = detect_running_services()

    Enum.map(service_defs, fn svc ->
      {active, node} = Map.get(running, svc.role, {false, nil})
      svc |> Map.put(:active, active) |> Map.put(:node, node)
    end)
  end

  # Checks local node + all connected peer nodes for each supervisor.
  # Returns %{role => {true | false, node_name}}
  defp detect_running_services do
    all_nodes = [node() | node_list_fun().()]
    running_on_node = supervisor_running_on_node_fun()

    Enum.reduce(@supervisor_map, %{}, fn {role, supervisor}, acc ->
      result = Enum.find_value(all_nodes, &running_on_node.(&1, supervisor))
      Map.put(acc, role, result || {false, nil})
    end)
  end

  # Test seams: keep remote-supervisor and telemetry fallback coverage stable
  # without requiring distributed peers or live NodeRouter replacement.
  defp node_list_fun,
    do: Application.get_env(:zaq, :dashboard_live_node_list_fun, &Node.list/0)

  defp supervisor_running_on_node_fun,
    do:
      Application.get_env(
        :zaq,
        :dashboard_live_supervisor_running_on_node_fun,
        &default_supervisor_running_on_node?/2
      )

  defp default_supervisor_running_on_node?(n, supervisor) when n == node() do
    if Process.whereis(supervisor) != nil, do: {true, n}
  end

  defp default_supervisor_running_on_node?(n, supervisor) do
    if :rpc.call(n, Process, :whereis, [supervisor]) != nil, do: {true, n}
  end

  defp load_main_dashboard_metrics do
    case node_router_module().invoke(:engine, Telemetry, :load_main_dashboard_metrics, [
           %{range: @kpi_range}
         ]) do
      %{metric_cards_chart: %{summary: %{metrics: metrics}}} when is_list(metrics) ->
        metrics

      _ ->
        default_telemetry_metric_cards()
    end
  rescue
    _ -> default_telemetry_metric_cards()
  end

  defp node_router_module,
    do: Application.get_env(:zaq, :dashboard_live_node_router_module, NodeRouter)

  defp default_telemetry_metric_cards do
    %{
      id: "main_dashboard_metrics",
      kind: :metric_cards,
      title: "Main dashboard metrics",
      labels: [],
      series: [],
      summary: %{
        metrics: [
          %{
            id: "dashboard-metric-documents-ingested",
            label: "Documents ingested",
            value: 0.0,
            unit: nil,
            trend: nil,
            hint: "ingestion pipeline completions",
            meta: %{range: @kpi_range, href: "/bo/ingestion"}
          },
          %{
            id: "dashboard-metric-llm-api-calls",
            label: "LLM API calls",
            value: 0,
            unit: nil,
            trend: nil,
            hint: "answering throughput",
            meta: %{range: @kpi_range, href: "/bo/ai-diagnostics"}
          },
          %{
            id: "dashboard-metric-qa-response-time",
            label: "Conversations average response time",
            value: 0.0,
            unit: "ms",
            trend: nil,
            hint: "weighted mean latency",
            meta: %{range: @kpi_range, href: "/bo/chat"}
          }
        ]
      },
      meta: %{range: @kpi_range}
    }
    |> DashboardChart.new()
    |> Map.get(:summary, %{})
    |> Map.get(:metrics, [])
  end
end
