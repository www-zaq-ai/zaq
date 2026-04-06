defmodule ZaqWeb.Live.BO.LLMPerformanceLive do
  use ZaqWeb, :live_view

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Contracts.DashboardChart
  alias Zaq.NodeRouter
  alias ZaqWeb.Helpers.MetricsHelpers

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
     |> assign_telemetry()}
  end

  @impl true
  def handle_event("set_range", %{"range" => range}, socket) do
    MetricsHelpers.handle_set_range(@ranges, range, socket, &assign_telemetry/1)
  end

  @impl true
  def handle_info(:refresh_telemetry, socket) do
    {:noreply, assign_telemetry(socket)}
  end

  defp assign_telemetry(socket) do
    telemetry = load_llm_performance_data(%{range: socket.assigns.range})
    llm_api_calls_chart = Map.get(telemetry, :llm_api_calls_chart, default_llm_api_calls_chart())
    token_usage_chart = Map.get(telemetry, :token_usage_chart, default_token_usage_chart())

    retrieval_effectiveness_chart =
      Map.get(telemetry, :retrieval_effectiveness_chart, default_retrieval_effectiveness_chart())

    socket
    |> assign(:telemetry, telemetry)
    |> assign(:llm_api_calls_chart, llm_api_calls_chart)
    |> assign(:token_usage_chart, token_usage_chart)
    |> assign(:retrieval_effectiveness_chart, retrieval_effectiveness_chart)
  end

  defp load_llm_performance_data(filters) do
    case NodeRouter.call(:engine, Telemetry, :load_llm_performance, [filters]) do
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
      retrieval_effectiveness_chart: default_retrieval_effectiveness_chart()
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

  defp labels_for_range(range), do: MetricsHelpers.labels_for_range(range)
end
