defmodule ZaqWeb.Live.BO.TelemetryPreviewLive do
  use ZaqWeb, :live_view

  alias Zaq.Engine.Telemetry
  alias Zaq.Engine.Telemetry.Contracts.DashboardChart
  alias Zaq.Engine.Telemetry.Contracts.{DisplayMeta, RuntimeMeta}
  alias Zaq.Engine.Telemetry.Contracts.Payloads.{ScalarPayload, SeriesPayload}
  alias Zaq.NodeRouter
  alias ZaqWeb.Live.BO.TelemetryPreviewData

  @required_chart_ids [
    "metric_cards",
    "time_series",
    "bar",
    "donut",
    "gauge",
    "status_grid",
    "progress",
    "radar"
  ]

  @default_metric %ScalarPayload{
    id: "metric-total-events",
    label: "Total Events",
    value: 0.0,
    unit: nil,
    trend: 0.0,
    display: %DisplayMeta{hint: ""},
    runtime: %RuntimeMeta{}
  }

  @impl true
  def mount(_params, _session, socket) do
    filters = TelemetryPreviewData.default_filters()

    {:ok,
     socket
     |> assign(:current_path, "/bo/dashboard")
     |> assign(:ranges, TelemetryPreviewData.available_ranges())
     |> assign(:segments, TelemetryPreviewData.available_segments())
     |> assign(:feedback_scopes, TelemetryPreviewData.available_feedback_scopes())
     |> assign(:series_keys, TelemetryPreviewData.available_series_keys())
     |> assign_filters(filters)
     |> assign_telemetry()}
  end

  @impl true
  def handle_event("set_range", %{"range" => range}, socket) do
    range =
      if range in TelemetryPreviewData.available_ranges(), do: range, else: socket.assigns.range

    {:noreply,
     socket
     |> assign(:range, range)
     |> assign_telemetry()}
  end

  def handle_event("toggle_benchmark", _params, socket) do
    {:noreply,
     socket
     |> assign(:benchmark_opt_in, !socket.assigns.benchmark_opt_in)
     |> assign_telemetry()}
  end

  def handle_event("set_segment", %{"segment" => segment}, socket) do
    segment =
      if segment in TelemetryPreviewData.available_segments(),
        do: segment,
        else: socket.assigns.segment

    {:noreply,
     socket
     |> assign(:segment, segment)
     |> assign_telemetry()}
  end

  def handle_event("set_feedback_scope", %{"scope" => scope}, socket) do
    scope =
      if scope in TelemetryPreviewData.available_feedback_scopes(),
        do: scope,
        else: socket.assigns.feedback_scope

    {:noreply,
     socket
     |> assign(:feedback_scope, scope)
     |> assign_telemetry()}
  end

  def handle_event("toggle_series", %{"series" => series_key}, socket) do
    visibility =
      if series_key in TelemetryPreviewData.available_series_keys() do
        Map.update!(socket.assigns.series_visibility, series_key, fn visible -> !visible end)
      else
        socket.assigns.series_visibility
      end

    {:noreply,
     socket
     |> assign(:series_visibility, visibility)
     |> assign_telemetry()}
  end

  defp assign_filters(socket, filters) do
    socket
    |> assign(:range, filters.range)
    |> assign(:benchmark_opt_in, filters.benchmark_opt_in)
    |> assign(:segment, filters.segment)
    |> assign(:feedback_scope, filters.feedback_scope)
    |> assign(:series_visibility, filters.series_visibility)
  end

  defp assign_telemetry(socket) do
    filters = %{
      range: socket.assigns.range,
      benchmark_opt_in: socket.assigns.benchmark_opt_in,
      segment: socket.assigns.segment,
      feedback_scope: socket.assigns.feedback_scope,
      series_visibility: socket.assigns.series_visibility
    }

    telemetry = load_dashboard_data(filters)

    charts = ensure_list(Map.get(telemetry, :charts, []))
    metric_cards = chart_or_default(charts, "metric_cards", :metric_cards)
    time_series_chart = chart_or_default(charts, "time_series", :time_series)
    gauge_chart = chart_or_default(charts, "gauge", :gauge)
    bar_chart = chart_or_default(charts, "bar", :bar)
    donut_chart = chart_or_default(charts, "donut", :donut)
    status_grid = chart_or_default(charts, "status_grid", :status_grid)
    progress_countdown = chart_or_default(charts, "progress", :progress)
    radar_chart = chart_or_default(charts, "radar", :radar)

    metrics = ensure_list(get_in(metric_cards, [:summary, :metrics]))
    gallery_metric = List.first(metrics) || @default_metric

    base_series =
      case time_series_chart do
        %DashboardChart{payload: %SeriesPayload{series: series}} -> series
        _ -> []
      end

    series_toggles = Enum.reject(base_series, &(&1.key == "benchmark"))

    visible_series =
      Enum.filter(series_toggles, fn series ->
        series.key != "benchmark" and Map.get(socket.assigns.series_visibility, series.key, true)
      end)

    composed_time_series_chart =
      with_visible_time_series(time_series_chart, visible_series, socket.assigns.benchmark_opt_in)

    socket
    |> assign(:telemetry, telemetry)
    |> assign(:metrics, metrics)
    |> assign(:gallery_metric, gallery_metric)
    |> assign(:time_series, time_series_chart)
    |> assign(:gauge_chart, gauge_chart)
    |> assign(:bar_chart, bar_chart)
    |> assign(:donut_chart, donut_chart)
    |> assign(:status_grid, status_grid)
    |> assign(:progress_countdown, progress_countdown)
    |> assign(:radar_chart, radar_chart)
    |> assign(:series_toggles, series_toggles)
    |> assign(:visible_time_series, visible_series)
    |> assign(:composed_time_series_chart, composed_time_series_chart)
  end

  defp load_dashboard_data(filters) do
    case NodeRouter.call(:engine, Telemetry, :load_dashboard, [filters]) do
      %{} = dashboard ->
        case normalize_dashboard(dashboard) do
          {:ok, normalized} -> normalized
          :error -> TelemetryPreviewData.build(filters)
        end

      _ ->
        TelemetryPreviewData.build(filters)
    end
  end

  defp normalize_dashboard(dashboard) do
    filters = ensure_map(get_in_contract(dashboard, :filters, %{}))
    charts = ensure_list(get_in_contract(dashboard, :charts, []))
    chart_index = chart_index(charts)

    if contract_valid?(filters, chart_index),
      do: {:ok, %{filters: filters, charts: charts}},
      else: :error
  end

  defp contract_valid?(filters, chart_index) when map_size(filters) > 0 do
    Enum.all?(@required_chart_ids, &Map.has_key?(chart_index, &1))
  end

  defp contract_valid?(_filters, _chart_index), do: false

  defp chart_index(charts) do
    Enum.reduce(charts, %{}, fn chart, acc ->
      case get_in_contract(chart, :id, nil) do
        id when is_binary(id) -> Map.put(acc, id, chart)
        _ -> acc
      end
    end)
  end

  defp chart_by_id(charts, id), do: Enum.find(charts, &(&1.id == id))

  defp chart_or_default(charts, id, kind) do
    chart_by_id(charts, id) ||
      DashboardChart.new(%{id: id, kind: kind, title: "", summary: %{}, meta: %{}})
  end

  defp with_visible_time_series(
         %DashboardChart{payload: %SeriesPayload{} = payload} = chart,
         visible_series,
         benchmark_opt_in
       ) do
    visible_keys = MapSet.new(Enum.map(visible_series, & &1.key))

    values =
      visible_series
      |> Enum.map(fn series -> {series.key, series.values} end)
      |> Map.new()

    benchmarks =
      if benchmark_opt_in do
        payload.benchmarks
        |> Enum.filter(fn {key, _values} -> MapSet.member?(visible_keys, to_string(key)) end)
        |> Map.new()
      else
        %{}
      end

    %DashboardChart{
      chart
      | payload: %SeriesPayload{payload | series: visible_series, benchmarks: benchmarks},
        series: visible_series,
        summary: Map.merge(chart.summary, %{values: values, benchmarks: benchmarks})
    }
  end

  defp with_visible_time_series(chart, _visible_series, _benchmark_opt_in), do: chart

  defp get_in_contract(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_in_contract(_value, _key, default), do: default

  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_), do: []

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}
end
