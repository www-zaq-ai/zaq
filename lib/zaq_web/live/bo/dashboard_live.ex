# lib/zaq_web/live/bo/dashboard_live.ex

defmodule ZaqWeb.Live.BO.DashboardLive do
  use ZaqWeb, :live_view

  alias Zaq.Accounts
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

    show_portal_banner = socket.assigns.current_user.portal_consent == "declined"
    user_email = socket.assigns.current_user.email

    {:ok,
     assign(socket,
       current_path: "/bo/dashboard",
       addon_data: addon_data,
       days_left: days_left,
       services: refresh_services(),
       metric_cards: telemetry_metrics,
       show_portal_banner: show_portal_banner,
       show_portal_consent_modal: false,
       portal_provision_error: nil,
       require_portal_email: blank?(user_email),
       portal_consent_email: user_email || ""
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
  def handle_event("show_portal_consent", _params, socket) do
    {:noreply, assign(socket, show_portal_consent_modal: true, portal_provision_error: nil)}
  end

  @impl true
  def handle_event("close_portal_consent_modal", _params, socket) do
    {:noreply, assign(socket, show_portal_consent_modal: false, portal_provision_error: nil)}
  end

  @impl true
  def handle_event("portal_consent_email_change", %{"email" => email}, socket) do
    {:noreply, assign(socket, portal_consent_email: email, portal_provision_error: nil)}
  end

  @impl true
  def handle_event("accept_portal_consent", _params, socket) do
    with {:ok, user} <-
           maybe_set_portal_email(
             socket.assigns.current_user,
             socket.assigns.portal_consent_email
           ),
         {:ok, updated_user} <- Accounts.provision_portal_for_user(user) do
      {:noreply,
       socket
       |> assign(:current_user, updated_user)
       |> assign(:show_portal_banner, false)
       |> assign(:show_portal_consent_modal, false)
       |> assign(:require_portal_email, false)
       |> assign(:portal_consent_email, updated_user.email)
       |> assign(:portal_provision_error, nil)
       |> put_flash(:info, "Free credits activated — your ZAQ portal account is ready.")}
    else
      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply,
         assign(socket,
           portal_provision_error: email_error_message(changeset),
           show_portal_consent_modal: true
         )}

      {:error, _reason} ->
        {:noreply,
         assign(socket,
           portal_provision_error: "Could not reach the ZAQ portal. Please try again later.",
           show_portal_consent_modal: true
         )}
    end
  end

  # -- Private --

  # Older accounts may not have an email on file. Persist the one entered in the
  # consent modal before provisioning; accounts that already have an email skip this.
  defp maybe_set_portal_email(user, entered_email) do
    if blank?(user.email) do
      Accounts.update_user(user, %{"email" => String.trim(entered_email || "")})
    else
      {:ok, user}
    end
  end

  defp email_error_message(changeset) do
    case changeset.errors[:email] do
      {message, _opts} -> "Email #{message}."
      # coveralls-ignore-next-line
      _ -> "Please enter a valid email address."
    end
  end

  defp blank?(value), do: not (is_binary(value) and String.trim(value) != "")

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

      # coveralls-ignore-next-line
      _ ->
        default_telemetry_metric_cards()
    end
  rescue
    # coveralls-ignore-next-line
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
    # coveralls-ignore-next-line
    |> Map.get(:metrics, [])
  end
end
