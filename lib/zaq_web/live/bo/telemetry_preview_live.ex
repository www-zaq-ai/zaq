defmodule ZaqWeb.Live.BO.TelemetryPreviewLive do
  use ZaqWeb, :live_view

  alias Zaq.NodeRouter
  alias Zaq.Engine.Telemetry
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

  @default_metric %{
    id: "metric-total-events",
    label: "Total Events",
    value: 0,
    unit: nil,
    trend: 0.0,
    hint: ""
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

    time_series =
      Map.get(telemetry, :time_series, %{labels: [], series: [], values: %{}, benchmarks: %{}})

    metrics = ensure_list(Map.get(telemetry, :metrics, []))
    gallery_metric = List.first(metrics) || @default_metric

    gauge_chart =
      Map.get(telemetry, :gauge_chart, %{value: 0.0, benchmark_value: nil, max: 100.0})

    bar_chart = Map.get(telemetry, :bar_chart, %{bars: []})
    donut_chart = Map.get(telemetry, :donut_chart, %{segments: []})
    status_grid = Map.get(telemetry, :status_grid, %{items: []})
    progress_countdown = Map.get(telemetry, :progress_countdown, %{total: 240, remaining: 240})
    radar_chart = Map.get(telemetry, :radar_chart, %{axes: [], benchmark_axes: []})

    visible_series =
      Enum.filter(time_series.series, fn series ->
        Map.get(socket.assigns.series_visibility, series.key, true)
      end)

    primary_chart_points = build_chart_points(time_series, visible_series, :primary)

    benchmark_chart_points =
      if socket.assigns.benchmark_opt_in do
        build_chart_points(time_series, visible_series, :benchmark)
      else
        []
      end

    socket
    |> assign(:telemetry, telemetry)
    |> assign(:metrics, metrics)
    |> assign(:gallery_metric, gallery_metric)
    |> assign(:time_series, time_series)
    |> assign(:gauge_chart, gauge_chart)
    |> assign(:bar_chart, bar_chart)
    |> assign(:donut_chart, donut_chart)
    |> assign(:status_grid, status_grid)
    |> assign(:progress_countdown, progress_countdown)
    |> assign(:radar_chart, radar_chart)
    |> assign(:visible_time_series, visible_series)
    |> assign(:time_series_points, primary_chart_points)
    |> assign(:benchmark_time_series_points, benchmark_chart_points)
  end

  defp build_chart_points(time_series, visible_series, lane) do
    labels_count = length(time_series.labels)

    if labels_count == 0 do
      []
    else
      Enum.map(0..(labels_count - 1), fn idx ->
        build_chart_point(time_series, visible_series, lane, idx)
      end)
    end
  end

  defp build_chart_point(time_series, [], _lane, idx) do
    %{label: label_for_index(time_series, idx), value: 0.0}
  end

  defp build_chart_point(time_series, visible_series, lane, idx) do
    values =
      Enum.map(visible_series, fn series ->
        series_point_value(time_series, series, idx, lane)
      end)

    %{
      label: label_for_index(time_series, idx),
      value: average(values)
    }
  end

  defp series_point_value(time_series, series, idx, :primary) do
    Enum.at(Map.get(time_series.values, series.key, []), idx, 0.0)
  end

  defp series_point_value(time_series, series, idx, :benchmark) do
    Enum.at(Map.get(time_series.benchmarks, series.key, []), idx, 0.0)
  end

  defp label_for_index(time_series, idx) do
    Enum.at(time_series.labels, idx, "T#{idx + 1}")
  end

  defp average(values) do
    values
    |> Enum.sum()
    |> Kernel./(length(values))
    |> Float.round(2)
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

    if contract_valid?(filters, chart_index) do
      metric_cards = chart_summary(chart_index, "metric_cards")
      time_series_chart = Map.get(chart_index, "time_series", %{})
      time_series_summary = chart_summary(chart_index, "time_series")
      bar_chart = chart_summary(chart_index, "bar")
      donut_chart = chart_summary(chart_index, "donut")
      gauge_chart = chart_summary(chart_index, "gauge")
      status_grid = chart_summary(chart_index, "status_grid")
      progress_countdown = chart_summary(chart_index, "progress")
      radar_chart = chart_summary(chart_index, "radar")

      {:ok,
       %{
         filters: filters,
         charts: charts,
         metrics: ensure_list(get_in_contract(metric_cards, :metrics, [])),
         time_series: %{
           labels: ensure_list(get_in_contract(time_series_summary, :labels, [])),
           series: normalize_time_series_series(get_in_contract(time_series_chart, :series, [])),
           values: ensure_map(get_in_contract(time_series_summary, :values, %{})),
           benchmarks: ensure_map(get_in_contract(time_series_summary, :benchmarks, %{}))
         },
         bar_chart: %{bars: ensure_list(get_in_contract(bar_chart, :bars, []))},
         donut_chart: %{segments: ensure_list(get_in_contract(donut_chart, :segments, []))},
         gauge_chart: %{
           value: to_float(get_in_contract(gauge_chart, :value, 0.0), 0.0),
           benchmark_value:
             to_optional_float(get_in_contract(gauge_chart, :benchmark_value, nil)),
           max: to_float(get_in_contract(gauge_chart, :max, 100.0), 100.0),
           label: get_in_contract(gauge_chart, :label, "target 80%")
         },
         status_grid: %{items: ensure_list(get_in_contract(status_grid, :items, []))},
         progress_countdown: %{
           total: to_integer(get_in_contract(progress_countdown, :total, 240), 240),
           remaining: to_integer(get_in_contract(progress_countdown, :remaining, 240), 240)
         },
         radar_chart: %{
           axes: ensure_list(get_in_contract(radar_chart, :axes, [])),
           benchmark_axes: ensure_list(get_in_contract(radar_chart, :benchmark_axes, []))
         }
       }}
    else
      :error
    end
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

  defp chart_summary(chart_index, chart_id) do
    chart_index
    |> Map.get(chart_id, %{})
    |> get_in_contract(:summary, %{})
    |> ensure_map()
  end

  defp normalize_time_series_series(series) do
    case ensure_list(series) do
      [] ->
        [
          %{key: "availability", name: "Availability"},
          %{key: "latency", name: "Latency"},
          %{key: "deflection", name: "Deflection"}
        ]

      values ->
        Enum.reduce(values, [], fn series_item, acc ->
          key = get_in_contract(series_item, :key, nil)
          name = get_in_contract(series_item, :name, nil)

          if is_binary(key) and is_binary(name) and key != "benchmark" do
            [%{key: key, name: name} | acc]
          else
            acc
          end
        end)
        |> Enum.reverse()
    end
  end

  defp get_in_contract(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp get_in_contract(_value, _key, default), do: default

  defp ensure_list(value) when is_list(value), do: value
  defp ensure_list(_), do: []

  defp ensure_map(value) when is_map(value), do: value
  defp ensure_map(_), do: %{}

  defp to_float(value, _default) when is_float(value), do: value
  defp to_float(value, _default) when is_integer(value), do: value * 1.0
  defp to_float(_, default), do: default

  defp to_optional_float(nil), do: nil
  defp to_optional_float(value), do: to_float(value, nil)

  defp to_integer(value, _default) when is_integer(value), do: value
  defp to_integer(value, _default) when is_float(value), do: trunc(value)
  defp to_integer(_, default), do: default
end
