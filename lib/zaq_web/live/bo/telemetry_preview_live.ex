defmodule ZaqWeb.Live.BO.TelemetryPreviewLive do
  use ZaqWeb, :live_view

  alias ZaqWeb.Live.BO.TelemetryPreviewData

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

    telemetry = TelemetryPreviewData.build(filters)

    visible_series =
      Enum.filter(telemetry.time_series.series, fn series ->
        Map.get(socket.assigns.series_visibility, series.key, true)
      end)

    chart_points =
      build_chart_points(
        telemetry.time_series,
        visible_series,
        socket.assigns.benchmark_opt_in
      )

    socket
    |> assign(:telemetry, telemetry)
    |> assign(:visible_time_series, visible_series)
    |> assign(:time_series_points, chart_points)
  end

  defp build_chart_points(time_series, visible_series, benchmark_opt_in) do
    labels_count = length(time_series.labels)

    if labels_count == 0 do
      []
    else
      Enum.map(0..(labels_count - 1), fn idx ->
        build_chart_point(time_series, visible_series, benchmark_opt_in, idx)
      end)
    end
  end

  defp build_chart_point(time_series, [], _benchmark_opt_in, idx) do
    %{label: label_for_index(time_series, idx), value: 0.0}
  end

  defp build_chart_point(time_series, visible_series, benchmark_opt_in, idx) do
    values =
      Enum.map(visible_series, fn series ->
        series_point_value(time_series, series, idx, benchmark_opt_in)
      end)

    %{
      label: label_for_index(time_series, idx),
      value: average(values)
    }
  end

  defp series_point_value(time_series, series, idx, false) do
    Enum.at(Map.get(time_series.values, series.key, []), idx, 0.0)
  end

  defp series_point_value(time_series, series, idx, true) do
    raw = series_point_value(time_series, series, idx, false)
    benchmark = Enum.at(Map.get(time_series.benchmarks, series.key, []), idx, raw)
    (raw + benchmark) / 2
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
end
