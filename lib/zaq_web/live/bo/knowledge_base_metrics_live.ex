defmodule ZaqWeb.Live.BO.KnowledgeBaseMetricsLive do
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
     |> assign(:current_path, "/bo/dashboard/knowledge-base-metrics")
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
    telemetry = load_knowledge_base_metrics_data(%{range: socket.assigns.range})

    total_chunks_created_chart =
      Map.get(telemetry, :total_chunks_created_chart, default_total_chunks_created_chart())

    ingestion_volume_chart =
      Map.get(telemetry, :ingestion_volume_chart, default_ingestion_volume_chart())

    ingestion_success_rate_chart =
      Map.get(
        telemetry,
        :ingestion_success_rate_chart,
        default_ingestion_success_rate_chart()
      )

    average_chunks_per_document_chart =
      Map.get(
        telemetry,
        :average_chunks_per_document_chart,
        default_average_chunks_per_document_chart()
      )

    socket
    |> assign(:telemetry, telemetry)
    |> assign(:total_chunks_created_chart, total_chunks_created_chart)
    |> assign(:ingestion_volume_chart, ingestion_volume_chart)
    |> assign(:ingestion_success_rate_chart, ingestion_success_rate_chart)
    |> assign(:average_chunks_per_document_chart, average_chunks_per_document_chart)
    |> assign(
      :total_chunks_card,
      first_metric_card(total_chunks_created_chart, default_total_chunks_created_card())
    )
    |> assign(
      :average_chunks_per_document_card,
      first_metric_card(
        average_chunks_per_document_chart,
        default_average_chunks_per_document_card()
      )
    )
  end

  defp load_knowledge_base_metrics_data(filters) do
    case NodeRouter.call(:engine, Telemetry, :load_knowledge_base_metrics, [filters]) do
      %{} = payload -> payload
      _ -> default_payload(filters)
    end
  rescue
    _ -> default_payload(filters)
  end

  defp default_payload(filters) do
    labels = labels_for_range(Map.get(filters, :range, "7d"))
    range = Map.get(filters, :range, "7d")

    %{
      filters: %{range: range},
      charts: [
        default_total_chunks_created_chart(range),
        default_ingestion_volume_chart(labels, range),
        default_ingestion_success_rate_chart(range),
        default_average_chunks_per_document_chart(range)
      ],
      total_chunks_created_chart: default_total_chunks_created_chart(range),
      ingestion_volume_chart: default_ingestion_volume_chart(labels, range),
      ingestion_success_rate_chart: default_ingestion_success_rate_chart(range),
      average_chunks_per_document_chart: default_average_chunks_per_document_chart(range)
    }
  end

  defp first_metric_card(%DashboardChart{summary: %{metrics: [%{} = metric | _]}}, _fallback),
    do: metric

  defp first_metric_card(_chart, fallback), do: fallback

  defp default_total_chunks_created_chart(range \\ "7d") do
    DashboardChart.new(%{
      id: "total_chunks_created",
      kind: :metric_cards,
      title: "Total chunks created",
      labels: [],
      series: [],
      summary: %{metrics: [default_total_chunks_created_card(range)]},
      meta: %{range: range}
    })
  end

  defp default_total_chunks_created_card(range \\ "7d") do
    %{
      id: "knowledge-base-total-chunks-created",
      label: "Total chunks created",
      value: 0.0,
      unit: nil,
      trend: nil,
      hint: "growth versus previous period",
      meta: %{range: range}
    }
  end

  defp default_ingestion_volume_chart(labels \\ labels_for_range("7d"), range \\ "7d") do
    zeroes = Enum.map(labels, fn _ -> 0.0 end)

    DashboardChart.new(%{
      id: "ingestion_volume_over_time",
      kind: :time_series,
      title: "Ingestion volume over time",
      labels: labels,
      series: [%{key: "documents_ingested", name: "Documents ingested", values: zeroes}],
      summary: %{labels: labels, values: %{"documents_ingested" => zeroes}},
      meta: %{range: range}
    })
  end

  defp default_ingestion_success_rate_chart(range \\ "7d") do
    DashboardChart.new(%{
      id: "ingestion_success_rate",
      kind: :gauge,
      title: "Ingestion success rate",
      labels: [],
      series: [],
      summary: %{value: 0.0, max: 100.0, label: "terminal document success"},
      meta: %{range: range}
    })
  end

  defp default_average_chunks_per_document_chart(range \\ "7d") do
    DashboardChart.new(%{
      id: "average_chunks_per_document",
      kind: :metric_cards,
      title: "Average chunks per document",
      labels: [],
      series: [],
      summary: %{metrics: [default_average_chunks_per_document_card(range)]},
      meta: %{range: range}
    })
  end

  defp default_average_chunks_per_document_card(range \\ "7d") do
    %{
      id: "knowledge-base-average-chunks-per-document",
      label: "Average chunks per document",
      value: 0.0,
      unit: nil,
      trend: nil,
      hint: "chunk density per successfully ingested document",
      meta: %{range: range}
    }
  end

  defp labels_for_range(range), do: MetricsHelpers.labels_for_range(range)
end
