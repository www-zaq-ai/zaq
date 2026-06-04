# lib/zaq_web/live/bo/dashboard_live.ex

defmodule ZaqWeb.Live.BO.DashboardLive do
  use ZaqWeb, :live_view

  alias Zaq.Addons.FeatureStore
  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Contracts.DashboardChart
  alias Zaq.NodeRouter

  @kpi_range "30d"

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

    {:ok,
     assign(socket,
       current_path: "/bo/dashboard",
       addon_data: addon_data,
       days_left: days_left,
       services: refresh_services(),
       metric_cards: telemetry_metrics
     )}
  end

  # -- Node event handlers --

  @impl true
  def handle_info({event, _node}, socket) when event in [:node_up, :node_down] do
    {:noreply, assign(socket, :services, refresh_services())}
  end

  @impl true
  def handle_info(:addons_updated, socket), do: {:noreply, socket}

  # -- Portal consent retry --
  @impl true
  def handle_info({:portal_flash, level, message}, socket) do
    {:noreply, put_flash(socket, level, message)}
  end

  @impl true
  def handle_info({:portal_user_updated, user}, socket) do
    {:noreply, assign(socket, :current_user, user)}
  end

  # -- Private --

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
