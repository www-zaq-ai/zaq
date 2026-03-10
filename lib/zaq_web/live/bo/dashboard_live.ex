# lib/zaq_web/live/bo/dashboard_live.ex

defmodule ZaqWeb.Live.BO.DashboardLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
  alias Zaq.License.FeatureStore

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

    license_data = FeatureStore.license_data()

    days_left =
      case license_data do
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
       license_data: license_data,
       days_left: days_left,
       services: refresh_services(),
       user_count: length(Accounts.list_users()),
       # Placeholders — wire up later
       session_count: 0,
       document_count: 0,
       embedding_count: 0,
       channel_count: 0
     )}
  end

  # -- Node event handlers --

  @impl true
  def handle_info({event, _node}, socket) when event in [:node_up, :node_down] do
    {:noreply, assign(socket, :services, refresh_services())}
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
    all_nodes = [node() | Node.list()]

    Enum.reduce(@supervisor_map, %{}, fn {role, supervisor}, acc ->
      result = Enum.find_value(all_nodes, &node_running_supervisor?(&1, supervisor))
      Map.put(acc, role, result || {false, nil})
    end)
  end

  defp node_running_supervisor?(n, supervisor) when n == node() do
    if Process.whereis(supervisor) != nil, do: {true, n}
  end

  defp node_running_supervisor?(n, supervisor) do
    if :rpc.call(n, Process, :whereis, [supervisor]) != nil, do: {true, n}
  end
end
