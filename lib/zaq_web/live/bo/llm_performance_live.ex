defmodule ZaqWeb.Live.BO.LLMPerformanceLive do
  use ZaqWeb, :live_view

  alias Zaq.Engine.Telemetry.Contracts.DashboardChart
  alias ZaqWeb.Components.DesignSystem.Table, as: DSTable
  alias ZaqWeb.Helpers.MetricsHelpers
  alias ZaqWeb.Helpers.TelemetryFormat
  alias ZaqWeb.Live.BO.EngineDispatch

  @ranges ["24h", "7d", "30d", "90d"]
  @refresh_interval_ms 15_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(@refresh_interval_ms, :refresh_telemetry)

    {:ok,
     socket
     |> assign(:current_path, "/bo/dashboard/llm-performance")
     |> assign(:ranges, @ranges)
     |> assign(:range, "7d")
     |> assign(:model_sort, "tokens")
     |> assign(:people_sort, "tokens")
     |> assign(:selected_agent_id, nil)
     |> assign_telemetry()}
  end

  @impl true
  def handle_event("set_range", %{"range" => range}, socket) do
    MetricsHelpers.handle_set_range(@ranges, range, socket, &assign_telemetry/1)
  end

  def handle_event("set_usage_sort", %{"ranking" => ranking, "sort" => sort}, socket)
      when ranking in ["models", "people"] and sort in ["tokens", "calls"] do
    assign_key = if ranking == "models", do: :model_sort, else: :people_sort
    {:noreply, socket |> assign(assign_key, sort) |> assign_telemetry()}
  end

  def handle_event("set_usage_sort", _params, socket), do: {:noreply, socket}

  def handle_event("select_agent", %{"agent_id" => agent_id}, socket) do
    selected_agent_id = if agent_id == "", do: nil, else: agent_id
    {:noreply, socket |> assign(:selected_agent_id, selected_agent_id) |> assign_telemetry()}
  end

  @impl true
  def handle_info(:refresh_telemetry, socket) do
    {:noreply, assign_telemetry(socket)}
  end

  defp assign_telemetry(socket) do
    telemetry =
      load_llm_performance_data(%{
        range: socket.assigns.range,
        model_sort: socket.assigns.model_sort,
        people_sort: socket.assigns.people_sort,
        agent_id: socket.assigns.selected_agent_id
      })

    llm_api_calls_chart = Map.get(telemetry, :llm_api_calls_chart, default_llm_api_calls_chart())
    token_usage_chart = Map.get(telemetry, :token_usage_chart, default_token_usage_chart())

    retrieval_effectiveness_chart =
      Map.get(telemetry, :retrieval_effectiveness_chart, default_retrieval_effectiveness_chart())

    agent_llm_api_calls_chart =
      Map.get(telemetry, :agent_llm_api_calls_chart, default_agent_llm_api_calls_chart())

    agent_token_usage_chart =
      Map.get(telemetry, :agent_token_usage_chart, default_agent_token_usage_chart())

    socket
    |> assign(:telemetry, telemetry)
    |> assign(:llm_api_calls_chart, llm_api_calls_chart)
    |> assign(:token_usage_chart, token_usage_chart)
    |> assign(:retrieval_effectiveness_chart, retrieval_effectiveness_chart)
    |> assign(:top_models, Map.get(telemetry, :top_models, []))
    |> assign(:top_people, Map.get(telemetry, :top_people, []))
    |> assign(:agents, Map.get(telemetry, :agents, []))
    |> assign(:agent_llm_api_calls_chart, agent_llm_api_calls_chart)
    |> assign(:agent_token_usage_chart, agent_token_usage_chart)
  end

  defp load_llm_performance_data(filters) do
    case EngineDispatch.dispatch(:telemetry_load_llm_performance, filters) do
      %{} = payload -> payload
      _ -> default_payload(filters)
    end
  rescue
    _ -> default_payload(filters)
  end

  defp default_payload(filters) do
    labels = labels_for_range(Map.get(filters, :range, "7d"))

    %{
      filters: %{range: Map.get(filters, :range, "7d")},
      charts: [
        default_llm_api_calls_chart(labels),
        default_token_usage_chart(labels),
        default_retrieval_effectiveness_chart()
      ],
      llm_api_calls_chart: default_llm_api_calls_chart(labels),
      token_usage_chart: default_token_usage_chart(labels),
      retrieval_effectiveness_chart: default_retrieval_effectiveness_chart(),
      top_models: [],
      top_people: [],
      agents: [],
      agent_llm_api_calls_chart: default_agent_llm_api_calls_chart(labels),
      agent_token_usage_chart: default_agent_token_usage_chart(labels)
    }
  end

  defp default_llm_api_calls_chart(labels \\ labels_for_range("7d")) do
    zeroes = Enum.map(labels, fn _ -> 0.0 end)

    DashboardChart.new(%{
      id: "llm_api_calls",
      kind: :time_series,
      title: "LLM API calls",
      labels: labels,
      series: [%{key: "calls", name: "API calls", values: zeroes}],
      summary: %{labels: labels, values: %{"calls" => zeroes}},
      meta: %{}
    })
  end

  defp default_token_usage_chart(labels \\ labels_for_range("7d")) do
    zeroes = Enum.map(labels, fn _ -> 0.0 end)

    DashboardChart.new(%{
      id: "token_usage",
      kind: :time_series,
      title: "Token usage",
      labels: labels,
      series: [
        %{key: "output_tokens", name: "Output token", values: zeroes},
        %{key: "input_tokens", name: "Input tokens", values: zeroes}
      ],
      summary: %{labels: labels, values: %{"output_tokens" => zeroes, "input_tokens" => zeroes}},
      meta: %{}
    })
  end

  defp default_retrieval_effectiveness_chart do
    DashboardChart.new(%{
      id: "retrieval_effectiveness",
      kind: :gauge,
      title: "Retrieval effectiveness",
      labels: [],
      series: [],
      summary: %{value: 0.0, max: 100.0, label: "strict no-answer adjusted"},
      meta: %{}
    })
  end

  defp default_agent_llm_api_calls_chart(labels \\ labels_for_range("7d")) do
    %{
      default_llm_api_calls_chart(labels)
      | id: "agent_llm_api_calls",
        title: "Agent LLM API calls"
    }
  end

  defp default_agent_token_usage_chart(labels \\ labels_for_range("7d")) do
    %{default_token_usage_chart(labels) | id: "agent_token_usage", title: "Agent token usage"}
  end

  attr :id, :string, required: true
  attr :rows, :list, required: true
  attr :entity, :atom, required: true, values: [:model, :person]

  def usage_table(assigns) do
    ~H"""
    <DSTable.table id={@id}>
      <:head>
        <DSTable.table_head_row>
          <DSTable.table_cell element={:th}>
            <DSTable.table_text
              label={if(@entity == :model, do: "Model", else: "Person")}
              tone={:tertiary}
            />
          </DSTable.table_cell>
          <DSTable.table_cell element={:th} align={:right}>
            <DSTable.table_text label="Total tokens" tone={:tertiary} />
          </DSTable.table_cell>
          <DSTable.table_cell element={:th} align={:right}>
            <DSTable.table_text label="Total calls" tone={:tertiary} />
          </DSTable.table_cell>
        </DSTable.table_head_row>
      </:head>
      <:body>
        <DSTable.table_empty :if={@rows == []} colspan={3}>
          No attributed usage in this range.
        </DSTable.table_empty>
        <DSTable.table_row :for={row <- @rows}>
          <DSTable.table_cell>
            <div class="flex flex-col min-w-0">
              <DSTable.table_text label={usage_label(row, @entity)} truncate />
              <DSTable.table_text
                :if={@entity == :model}
                label={row.provider}
                tone={:tertiary}
                truncate
              />
            </div>
          </DSTable.table_cell>
          <DSTable.table_cell align={:right}>
            <DSTable.table_text label={TelemetryFormat.format_value(row.total_tokens)} tone={:mono} />
          </DSTable.table_cell>
          <DSTable.table_cell align={:right}>
            <DSTable.table_text label={TelemetryFormat.format_value(row.total_calls)} tone={:mono} />
          </DSTable.table_cell>
        </DSTable.table_row>
      </:body>
    </DSTable.table>
    """
  end

  defp usage_label(row, :model), do: row.model
  defp usage_label(row, :person), do: row.name

  defp labels_for_range(range), do: MetricsHelpers.labels_for_range(range)
end
