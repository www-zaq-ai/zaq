defmodule ZaqWeb.Live.BO.ConversationsMetricsLive do
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
     |> assign(:current_path, "/bo/dashboard/conversations-metrics")
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
    telemetry = load_conversations_metrics_data(%{range: socket.assigns.range})

    messages_received_chart =
      Map.get(telemetry, :messages_received_chart, default_messages_received_chart())

    messages_per_channel_chart =
      Map.get(telemetry, :messages_per_channel_chart, default_messages_per_channel_chart())

    answer_confidence_distribution_chart =
      Map.get(
        telemetry,
        :answer_confidence_distribution_chart,
        default_answer_confidence_distribution_chart()
      )

    no_answer_rate_chart =
      Map.get(telemetry, :no_answer_rate_chart, default_no_answer_rate_chart())

    average_response_time_chart =
      Map.get(telemetry, :average_response_time_chart, default_average_response_time_chart())

    socket
    |> assign(:telemetry, telemetry)
    |> assign(:messages_received_chart, messages_received_chart)
    |> assign(:messages_per_channel_chart, messages_per_channel_chart)
    |> assign(:answer_confidence_distribution_chart, answer_confidence_distribution_chart)
    |> assign(:no_answer_rate_chart, no_answer_rate_chart)
    |> assign(:average_response_time_chart, average_response_time_chart)
  end

  defp load_conversations_metrics_data(filters) do
    case NodeRouter.call(:engine, Telemetry, :load_conversations_metrics, [filters]) do
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
        default_messages_received_chart(labels),
        default_messages_per_channel_chart(),
        default_answer_confidence_distribution_chart(),
        default_no_answer_rate_chart(labels),
        default_average_response_time_chart(labels)
      ],
      messages_received_chart: default_messages_received_chart(labels),
      messages_per_channel_chart: default_messages_per_channel_chart(),
      answer_confidence_distribution_chart: default_answer_confidence_distribution_chart(),
      no_answer_rate_chart: default_no_answer_rate_chart(labels),
      average_response_time_chart: default_average_response_time_chart(labels)
    }
  end

  defp default_messages_received_chart(labels \\ labels_for_range("7d")) do
    zeroes = Enum.map(labels, fn _ -> 0.0 end)

    DashboardChart.new(%{
      id: "messages_received",
      kind: :time_series,
      title: "Questions asked",
      labels: labels,
      series: [%{key: "messages", name: "Messages (cumulative)", values: zeroes}],
      summary: %{labels: labels, values: %{"messages" => zeroes}},
      meta: %{}
    })
  end

  defp default_messages_per_channel_chart do
    DashboardChart.new(%{
      id: "messages_per_channel",
      kind: :donut,
      title: "Questions per channel",
      labels: [],
      series: [],
      summary: %{segments: [%{label: "unknown", value: 0.0}]},
      meta: %{}
    })
  end

  defp default_answer_confidence_distribution_chart do
    DashboardChart.new(%{
      id: "answer_confidence_distribution",
      kind: :radar,
      title: "Answer confidence distribution",
      labels: [],
      series: [],
      summary: %{
        axes: [
          %{label: "Over 90", value: 0.0},
          %{label: "80-90", value: 0.0},
          %{label: "70-80", value: 0.0},
          %{label: "50-70", value: 0.0},
          %{label: "Below 50", value: 0.0}
        ]
      },
      meta: %{}
    })
  end

  defp default_no_answer_rate_chart(labels \\ labels_for_range("7d")) do
    zeroes = Enum.map(labels, fn _ -> 0.0 end)

    DashboardChart.new(%{
      id: "no_answer_rate",
      kind: :time_series,
      title: "No-answer rate",
      labels: labels,
      baseline: %{for: "no_answer_rate", value: 10.0, label: "Alert threshold"},
      series: [%{key: "no_answer_rate", name: "No-answer rate", values: zeroes}],
      summary: %{labels: labels, values: %{"no_answer_rate" => zeroes}},
      meta: %{threshold_percent: 10.0}
    })
  end

  defp default_average_response_time_chart(labels \\ labels_for_range("7d")) do
    zeroes = Enum.map(labels, fn _ -> 0.0 end)

    DashboardChart.new(%{
      id: "average_response_time",
      kind: :time_series,
      title: "Average response time",
      labels: labels,
      baseline: %{for: "average_response_time", value: 1500.0, label: "SLA"},
      series: [%{key: "average_response_time", name: "Average response time", values: zeroes}],
      summary: %{labels: labels, values: %{"average_response_time" => zeroes}},
      meta: %{sla_ms: 1500.0}
    })
  end

  defp labels_for_range(range), do: MetricsHelpers.labels_for_range(range)
end
