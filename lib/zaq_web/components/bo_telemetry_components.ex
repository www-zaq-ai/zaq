defmodule ZaqWeb.Components.BOTelemetryComponents do
  @moduledoc """
  Reusable BO telemetry function components.
  """

  use Phoenix.Component

  @accent "#03b6d4"

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :any, default: nil
  attr :unit, :string, default: nil
  attr :trend, :float, default: nil
  attr :hint, :string, default: nil

  def metric_card(assigns) do
    ~H"""
    <article
      id={@id}
      class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm transition-all duration-200 hover:border-cyan-300 hover:shadow"
    >
      <p class="font-mono text-[0.65rem] uppercase tracking-[0.18em] text-slate-500">{@label}</p>
      <div class="mt-3 flex items-end justify-between gap-3">
        <p class="text-3xl font-semibold tracking-tight text-slate-900">
          {format_value(@value)}<span :if={@unit} class="ml-1 text-sm text-slate-500">{@unit}</span>
        </p>
        <p
          :if={is_number(@trend)}
          class={[
            "rounded-full px-2 py-1 font-mono text-[0.68rem] transition-colors",
            if(@trend >= 0,
              do: "bg-cyan-50 text-cyan-700",
              else: "bg-slate-100 text-slate-600"
            )
          ]}
        >
          {trend_label(@trend)}
        </p>
      </div>
      <p :if={@hint} class="mt-3 text-xs text-slate-500">{@hint}</p>
    </article>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, default: "Time series"
  attr :points, :list, default: []
  attr :width, :integer, default: 420
  attr :height, :integer, default: 180

  def time_series_chart(assigns) do
    chart = build_line_chart(assigns.points, assigns.width, assigns.height)
    assigns = assign(assigns, :chart, chart)

    ~H"""
    <section
      id={@id}
      phx-hook="ChartTooltip"
      class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"
    >
      <div class="mb-3 flex items-center justify-between">
        <p class="font-mono text-[0.65rem] uppercase tracking-[0.18em] text-slate-500">{@title}</p>
        <p class="font-mono text-[0.68rem] text-cyan-700">line</p>
      </div>

      <div
        :if={@chart.empty?}
        class="grid h-32 place-items-center rounded-xl border border-dashed border-slate-200"
      >
        <p class="font-mono text-xs text-slate-500">No data</p>
      </div>

      <svg :if={!@chart.empty?} viewBox={"0 0 #{@width} #{@height}"} class="h-40 w-full">
        <line
          x1={@chart.left}
          y1={@chart.bottom}
          x2={@chart.right}
          y2={@chart.bottom}
          stroke="#cbd5e1"
          stroke-width="1"
        />
        <line
          x1={@chart.left}
          y1={@chart.top}
          x2={@chart.left}
          y2={@chart.bottom}
          stroke="#cbd5e1"
          stroke-width="1"
        />
        <path d={@chart.area_path} fill="rgba(3, 182, 212, 0.12)" />
        <polyline
          points={@chart.polyline_points}
          fill="none"
          stroke="#03b6d4"
          stroke-width="2.5"
          stroke-linecap="round"
          stroke-linejoin="round"
        />
        <circle
          :for={point <- @chart.marker_points}
          cx={point.x}
          cy={point.y}
          r="4.5"
          fill={point.color}
          stroke="#ffffff"
          stroke-width="1.5"
          class="cursor-pointer transition-all duration-200 hover:r-[6]"
          data-tip-label={point.label}
          data-tip-value={format_value(point.value)}
          data-tip-color={point.color}
          tabindex="0"
        >
          <title>{point.label <> ": " <> format_value(point.value)}</title>
        </circle>
        <line
          :for={tick <- @chart.x_ticks}
          x1={tick.x}
          y1={@chart.bottom}
          x2={tick.x}
          y2={@chart.bottom + 4}
          stroke="#94a3b8"
          stroke-width="1"
        />
        <text
          :for={tick <- @chart.x_ticks}
          x={tick.x}
          y={@chart.bottom + 14}
          fill="#64748b"
          font-size="10"
          font-family="ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
          text-anchor={tick.anchor}
          data-line-x-axis-label={tick.label}
        >
          {tick.label}
        </text>
      </svg>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, default: "Bars"
  attr :bars, :list, default: []

  def bar_chart(assigns) do
    bars = normalize_bars(assigns.bars)
    max_value = max_value(bars)
    assigns = assign(assigns, bars: bars, max_value: max_value)

    ~H"""
    <section id={@id} class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <p class="mb-3 font-mono text-[0.65rem] uppercase tracking-[0.18em] text-slate-500">{@title}</p>

      <div
        :if={Enum.empty?(@bars)}
        class="grid h-32 place-items-center rounded-xl border border-dashed border-slate-200"
      >
        <p class="font-mono text-xs text-slate-500">No data</p>
      </div>

      <div :if={!Enum.empty?(@bars)} class="space-y-2.5">
        <div :for={bar <- @bars} class="space-y-1">
          <div class="flex items-center justify-between text-xs text-slate-600">
            <span class="font-mono">{bar.label}</span>
            <span class="font-mono text-slate-500">{format_value(bar.value)}</span>
          </div>
          <div class="h-2.5 overflow-hidden rounded-full bg-slate-100">
            <div
              class="h-full rounded-full bg-cyan-500 transition-all duration-300"
              style={"width: #{bar_width(bar.value, @max_value)}%"}
            />
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, default: "Distribution"
  attr :segments, :list, default: []

  def donut_chart(assigns) do
    segments = normalize_segments(assigns.segments)
    donut = build_donut(segments)
    assigns = assign(assigns, segments: segments, donut: donut)

    ~H"""
    <section
      id={@id}
      phx-hook="ChartTooltip"
      class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"
    >
      <p class="mb-3 font-mono text-[0.65rem] uppercase tracking-[0.18em] text-slate-500">{@title}</p>

      <div class="flex items-center gap-4">
        <svg viewBox="0 0 120 120" class="h-28 w-28 shrink-0">
          <circle cx="60" cy="60" r="42" fill="none" stroke="#e2e8f0" stroke-width="14" />
          <circle
            :if={@donut.empty?}
            cx="60"
            cy="60"
            r="42"
            fill="none"
            stroke="#cbd5e1"
            stroke-width="14"
            stroke-dasharray="2 6"
          />
          <circle
            :for={segment <- @donut.arcs}
            cx="60"
            cy="60"
            r="42"
            fill="none"
            stroke={segment.color}
            stroke-width="14"
            stroke-linecap="butt"
            stroke-dasharray={segment.dasharray}
            stroke-dashoffset={segment.dashoffset}
            transform="rotate(-90 60 60)"
            class="cursor-pointer"
            data-tip-label={segment.label}
            data-tip-value={
              format_value(segment.value) <> " (" <> Integer.to_string(segment.percent) <> "%)"
            }
            data-tip-color={segment.color}
            tabindex="0"
          >
            <title>
              {segment.label <>
                ": " <>
                format_value(segment.value) <>
                " (" <>
                Integer.to_string(segment.percent) <> "%)"}
            </title>
          </circle>
        </svg>

        <div class="min-w-0 flex-1 space-y-1.5">
          <p :if={@donut.empty?} class="font-mono text-xs text-slate-500">No data</p>
          <div :for={segment <- @donut.legend} class="flex items-center justify-between text-xs">
            <span class="flex items-center gap-2 font-mono text-slate-600">
              <span
                class="inline-block h-2 w-2 rounded-full"
                style={"background-color: #{segment.color}"}
              />
              {segment.label}
            </span>
            <span class="font-mono text-slate-500">
              {format_value(segment.value)} ({segment.percent}%)
            </span>
          </div>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, default: "Gauge"
  attr :value, :float, default: 0.0
  attr :min, :float, default: 0.0
  attr :max, :float, default: 100.0

  def gauge_chart(assigns) do
    gauge = build_gauge(assigns.value, assigns.min, assigns.max)
    assigns = assign(assigns, :gauge, gauge)

    ~H"""
    <section
      id={@id}
      data-pointer-x={@gauge.pointer_x}
      data-pointer-y={@gauge.pointer_y}
      data-gauge-ratio={@gauge.ratio}
      class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"
    >
      <p class="mb-3 font-mono text-[0.65rem] uppercase tracking-[0.18em] text-slate-500">{@label}</p>

      <svg viewBox="0 0 220 130" class="h-32 w-full">
        <polyline
          points={@gauge.base_points}
          fill="none"
          stroke="#e2e8f0"
          stroke-width="14"
          stroke-linecap="round"
        />
        <polyline
          :if={@gauge.value_points != ""}
          points={@gauge.value_points}
          fill="none"
          stroke="#03b6d4"
          stroke-width="14"
          stroke-linecap="round"
        />
        <line
          x1="110"
          y1="110"
          x2={@gauge.pointer_x}
          y2={@gauge.pointer_y}
          stroke="#0f172a"
          stroke-width="2"
        />
        <circle cx="110" cy="110" r="4" fill="#0f172a" />
      </svg>

      <div class="mt-2 flex items-end justify-between">
        <p class="text-2xl font-semibold text-slate-900">{format_value(@gauge.current)}</p>
        <p class="font-mono text-xs text-slate-500">{format_value(@min)} - {format_value(@max)}</p>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, default: "Status"
  attr :items, :list, default: []

  def status_grid(assigns) do
    items = normalize_status_items(assigns.items)
    assigns = assign(assigns, :items, items)

    ~H"""
    <section id={@id} class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <p class="mb-3 font-mono text-[0.65rem] uppercase tracking-[0.18em] text-slate-500">{@title}</p>

      <div
        :if={Enum.empty?(@items)}
        class="grid h-32 place-items-center rounded-xl border border-dashed border-slate-200"
      >
        <p class="font-mono text-xs text-slate-500">No data</p>
      </div>

      <div :if={!Enum.empty?(@items)} class="grid grid-cols-1 gap-2 sm:grid-cols-2">
        <div
          :for={item <- @items}
          class="rounded-xl border border-slate-200 p-3 transition-colors hover:border-cyan-300"
        >
          <div class="flex items-center justify-between gap-3">
            <p class="font-mono text-xs text-slate-700">{item.label}</p>
            <span class={[
              "inline-flex h-2.5 w-2.5 rounded-full",
              status_dot_class(item.status)
            ]} />
          </div>
          <p class="mt-1 text-xs text-slate-500">{item.detail}</p>
        </div>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, default: "Countdown"
  attr :total, :integer, default: 100
  attr :remaining, :integer, default: 0

  def progress_countdown(assigns) do
    progress = build_progress(assigns.total, assigns.remaining)
    assigns = assign(assigns, :progress, progress)

    ~H"""
    <section id={@id} class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm">
      <div class="mb-3 flex items-center justify-between">
        <p class="font-mono text-[0.65rem] uppercase tracking-[0.18em] text-slate-500">{@label}</p>
        <p class="font-mono text-xs text-cyan-700">{@progress.percent}%</p>
      </div>
      <div class="h-2.5 overflow-hidden rounded-full bg-slate-100">
        <div
          class="h-full rounded-full bg-cyan-500 transition-all duration-300"
          style={"width: #{@progress.percent}%"}
        />
      </div>
      <div class="mt-3 flex items-end justify-between">
        <p class="text-2xl font-semibold text-slate-900">{@progress.remaining}</p>
        <p class="font-mono text-xs text-slate-500">remaining of {@progress.total}</p>
      </div>
    </section>
    """
  end

  attr :id, :string, required: true
  attr :title, :string, default: "Radar"
  attr :axes, :list, default: []
  attr :size, :integer, default: 220

  def radar_chart(assigns) do
    radar = build_radar(assigns.axes, assigns.size)
    assigns = assign(assigns, :radar, radar)

    ~H"""
    <section
      id={@id}
      phx-hook="ChartTooltip"
      class="rounded-2xl border border-slate-200 bg-white p-4 shadow-sm"
    >
      <p class="mb-3 font-mono text-[0.65rem] uppercase tracking-[0.18em] text-slate-500">{@title}</p>

      <div
        :if={@radar.empty?}
        class="grid h-48 place-items-center rounded-xl border border-dashed border-slate-200"
      >
        <p class="font-mono text-xs text-slate-500">No data</p>
      </div>

      <div :if={!@radar.empty?} class="flex flex-col gap-3 lg:flex-row lg:items-center">
        <svg viewBox={"0 0 #{@size} #{@size}"} class="h-52 w-full max-w-[260px]">
          <polygon
            :for={ring <- @radar.rings}
            points={ring}
            fill="none"
            stroke="#e2e8f0"
            stroke-width="1"
          />
          <line
            :for={axis <- @radar.axes}
            x1={@radar.cx}
            y1={@radar.cy}
            x2={axis.x}
            y2={axis.y}
            stroke="#cbd5e1"
            stroke-width="1"
          />
          <polygon
            points={@radar.value_polygon}
            fill="rgba(3, 182, 212, 0.18)"
            stroke="#03b6d4"
            stroke-width="2"
          />
          <circle
            :for={point <- @radar.value_points}
            cx={point.x}
            cy={point.y}
            r="4.5"
            fill={point.color}
            stroke="#ffffff"
            stroke-width="1.5"
            class="cursor-pointer"
            data-tip-label={point.label}
            data-tip-value={format_value(point.value)}
            data-tip-color={point.color}
            tabindex="0"
          >
            <title>{point.label <> ": " <> format_value(point.value)}</title>
          </circle>
        </svg>

        <div class="grid flex-1 grid-cols-2 gap-2">
          <div
            :for={axis <- @radar.legend}
            data-radar-label={axis.label}
            data-radar-color={axis.color}
            class="rounded-lg border border-slate-200 px-2.5 py-2"
          >
            <p class="flex items-center gap-2 font-mono text-[0.65rem] text-slate-500">
              <span
                class="inline-block h-2 w-2 rounded-full"
                style={"background-color: #{axis.color}"}
              />
              {axis.label}
            </p>
            <p class="text-sm font-medium text-slate-800">{format_value(axis.value)}</p>
          </div>
        </div>
      </div>
    </section>
    """
  end

  defp normalize_bars(bars) do
    bars
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn
      {%{label: label, value: value}, _idx} -> %{label: to_string(label), value: to_number(value)}
      {value, idx} when is_number(value) -> %{label: "#{idx + 1}", value: to_number(value)}
      {_, idx} -> %{label: "#{idx + 1}", value: 0.0}
    end)
  end

  defp normalize_segments(segments) do
    segments
    |> List.wrap()
    |> Enum.with_index()
    |> Enum.map(fn
      {%{label: label, value: value}, idx} ->
        %{label: to_string(label), value: max(to_number(value), 0.0), color: palette(idx)}

      {value, idx} when is_number(value) ->
        %{label: "#{idx + 1}", value: max(to_number(value), 0.0), color: palette(idx)}

      {_, idx} ->
        %{label: "#{idx + 1}", value: 0.0, color: palette(idx)}
    end)
  end

  defp normalize_status_items(items) do
    items
    |> List.wrap()
    |> Enum.map(fn
      %{label: label, status: status} = item ->
        %{
          label: to_string(label),
          status: normalize_status(status),
          detail: Map.get(item, :detail, "")
        }

      item when is_binary(item) ->
        %{label: item, status: :unknown, detail: ""}

      _ ->
        %{label: "Unknown", status: :unknown, detail: ""}
    end)
  end

  defp build_line_chart(points, width, height) do
    left = 24
    right = max(width - 12, left + 1)
    top = 14
    bottom = max(height - 22, top + 1)

    normalized_points =
      points
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn
        {%{label: label, value: value}, _idx} ->
          %{label: to_string(label), value: to_number(value), color: @accent}

        {%{x: label, y: value}, _idx} ->
          %{label: to_string(label), value: to_number(value), color: @accent}

        {%{y: value} = point, idx} ->
          %{
            label: to_string(Map.get(point, :label, "T#{idx + 1}")),
            value: to_number(value),
            color: @accent
          }

        {value, idx} when is_number(value) ->
          %{label: "T#{idx + 1}", value: to_number(value), color: @accent}

        {_, idx} ->
          %{label: "T#{idx + 1}", value: 0.0, color: @accent}
      end)

    values = Enum.map(normalized_points, & &1.value)

    if Enum.empty?(values) do
      %{
        empty?: true,
        left: left,
        right: right,
        top: top,
        bottom: bottom,
        polyline_points: "",
        area_path: "",
        marker_points: [],
        x_ticks: []
      }
    else
      min_y = Enum.min(values)
      max_y = Enum.max(values)
      span_y = if max_y == min_y, do: 1.0, else: max_y - min_y
      count = length(values)

      points_xy =
        normalized_points
        |> Enum.with_index()
        |> Enum.map(fn {point, idx} ->
          build_line_marker(point, idx, %{
            left: left,
            right: right,
            count: count,
            min_y: min_y,
            span_y: span_y,
            bottom: bottom,
            top: top
          })
        end)

      polyline_points =
        Enum.map_join(points_xy, " ", fn point -> "#{point.x},#{point.y}" end)

      first_point = hd(points_xy)
      last_point = List.last(points_xy)

      area_path =
        "M #{polyline_points} L #{last_point.x} #{round2(bottom)} L #{first_point.x} #{round2(bottom)} Z"

      %{
        empty?: false,
        left: left,
        right: right,
        top: top,
        bottom: bottom,
        polyline_points: polyline_points,
        area_path: area_path,
        marker_points: points_xy,
        x_ticks: build_line_x_ticks(points_xy)
      }
    end
  end

  defp build_donut(segments) do
    total = Enum.reduce(segments, 0.0, fn segment, acc -> acc + segment.value end)
    radius = 42.0
    circumference = 2.0 * :math.pi() * radius

    if total <= 0.0 do
      %{empty?: true, arcs: [], legend: []}
    else
      {arcs, _offset} =
        Enum.map_reduce(segments, 0.0, fn segment, offset ->
          build_donut_arc(segment, offset, total, circumference)
        end)

      legend =
        Enum.map(segments, fn segment ->
          %{
            label: segment.label,
            value: segment.value,
            color: segment.color,
            percent: round(segment.value / total * 100)
          }
        end)

      %{empty?: false, arcs: Enum.reject(arcs, &is_nil/1), legend: legend}
    end
  end

  defp build_gauge(value, min, max) do
    clean_min = to_number(min)
    clean_max = if to_number(max) <= clean_min, do: clean_min + 1.0, else: to_number(max)
    current = clamp(to_number(value), clean_min, clean_max)
    ratio = clamp((current - clean_min) / (clean_max - clean_min), 0.0, 1.0)

    start_angle = 180.0
    end_angle = 360.0
    value_angle = start_angle + (end_angle - start_angle) * ratio

    base_points = semicircle_points(110.0, 110.0, 80.0, start_angle, end_angle, 56)

    value_points =
      if ratio <= 0.0 do
        ""
      else
        steps = max(2, round(56 * ratio))
        semicircle_points(110.0, 110.0, 80.0, start_angle, value_angle, steps)
      end

    {pointer_x, pointer_y} = polar_to_cartesian(110.0, 110.0, 64.0, value_angle)

    %{
      empty?: false,
      ratio: round2(ratio),
      current: current,
      base_points: base_points,
      value_points: value_points,
      pointer_x: round2(pointer_x),
      pointer_y: round2(pointer_y)
    }
  end

  defp build_progress(total, remaining) do
    total_value = max(total, 0)
    remaining_value = clamp(remaining, 0, total_value)
    completed = max(total_value - remaining_value, 0)
    percent = if total_value == 0, do: 0, else: round(completed / total_value * 100)

    %{total: total_value, remaining: remaining_value, percent: percent}
  end

  defp build_radar(axes, size) do
    axis_list =
      axes
      |> List.wrap()
      |> Enum.with_index()
      |> Enum.map(fn
        {%{label: label, value: value}, idx} ->
          %{label: to_string(label), value: max(to_number(value), 0.0), color: palette(idx)}

        {value, idx} when is_number(value) ->
          %{label: "Axis #{idx + 1}", value: max(to_number(value), 0.0), color: palette(idx)}

        {_, idx} ->
          %{label: "Axis #{idx + 1}", value: 0.0, color: palette(idx)}
      end)

    count = length(axis_list)

    if count < 3 do
      %{empty?: true}
    else
      cx = size / 2
      cy = size / 2
      radius = size * 0.36
      max_axis = max_value(axis_list)
      clean_max = if max_axis <= 0, do: 1.0, else: max_axis

      angles = Enum.map(0..(count - 1), fn idx -> -90 + idx * 360 / count end)

      axes_coords =
        Enum.map(angles, fn angle ->
          {x, y} = polar_to_cartesian(cx, cy, radius, angle)
          %{x: round2(x), y: round2(y)}
        end)

      value_points =
        Enum.zip(axis_list, angles)
        |> Enum.map(fn {axis, angle} ->
          scaled_radius = radius * clamp(axis.value / clean_max, 0.0, 1.0)
          {x, y} = polar_to_cartesian(cx, cy, scaled_radius, angle)

          %{
            x: round2(x),
            y: round2(y),
            label: axis.label,
            value: axis.value,
            color: axis.color
          }
        end)

      rings =
        Enum.map(1..4, fn level ->
          ring_radius = radius * level / 4
          radar_ring_points(angles, cx, cy, ring_radius)
        end)

      value_polygon =
        Enum.map_join(value_points, " ", fn point -> "#{point.x},#{point.y}" end)

      %{
        empty?: false,
        cx: round2(cx),
        cy: round2(cy),
        axes: axes_coords,
        rings: rings,
        value_polygon: value_polygon,
        value_points: value_points,
        legend: axis_list
      }
    end
  end

  defp build_line_marker(point, idx, geometry) do
    x = line_x(geometry.left, geometry.right, geometry.count, idx)

    y =
      geometry.bottom -
        (point.value - geometry.min_y) / geometry.span_y * (geometry.bottom - geometry.top)

    %{
      x: round2(x),
      y: round2(y),
      value: point.value,
      label: point.label,
      color: point.color
    }
  end

  defp line_x(left, _right, 1, _idx), do: left
  defp line_x(left, right, count, idx), do: left + idx * (right - left) / (count - 1)

  defp build_line_x_ticks(points_xy) do
    points_xy
    |> line_tick_indexes()
    |> Enum.map(fn idx ->
      point = Enum.at(points_xy, idx)

      %{
        x: point.x,
        label: point.label,
        anchor: tick_anchor(idx, length(points_xy))
      }
    end)
  end

  defp line_tick_indexes(points_xy) do
    count = length(points_xy)

    cond do
      count == 0 ->
        []

      count <= 8 ->
        Enum.to_list(0..(count - 1))

      true ->
        step = div(count + 3, 5)

        0..(count - 1)
        |> Enum.filter(&(rem(&1, step) == 0))
        |> then(fn indexes -> Enum.uniq(indexes ++ [count - 1]) end)
    end
  end

  defp tick_anchor(0, _count), do: "start"
  defp tick_anchor(idx, count) when idx == count - 1, do: "end"
  defp tick_anchor(_idx, _count), do: "middle"

  defp build_donut_arc(segment, offset, total, circumference) do
    ratio = segment.value / total
    length = circumference * ratio

    {
      donut_arc_payload(segment, ratio, length, circumference, offset),
      offset + length
    }
  end

  defp donut_arc_payload(_segment, _ratio, length, _circumference, _offset) when length <= 0.0,
    do: nil

  defp donut_arc_payload(segment, ratio, length, circumference, offset) do
    %{
      label: segment.label,
      value: segment.value,
      color: segment.color,
      percent: round(ratio * 100),
      dasharray: "#{round2(length)} #{round2(circumference - length)}",
      dashoffset: "#{round2(-offset)}"
    }
  end

  defp radar_ring_points(angles, cx, cy, ring_radius) do
    Enum.map_join(angles, " ", fn angle ->
      {x, y} = polar_to_cartesian(cx, cy, ring_radius, angle)
      "#{round2(x)},#{round2(y)}"
    end)
  end

  defp max_value(items) do
    items
    |> Enum.map(fn
      %{value: value} -> value
      value when is_number(value) -> value
      _ -> 0
    end)
    |> case do
      [] -> 0.0
      values -> Enum.max(values)
    end
  end

  defp bar_width(_value, max_value) when max_value <= 0, do: 0
  defp bar_width(value, max_value), do: round(clamp(value / max_value, 0.0, 1.0) * 100)

  defp normalize_status(:ok), do: :ok
  defp normalize_status(:up), do: :ok
  defp normalize_status(:warn), do: :warn
  defp normalize_status(:warning), do: :warn
  defp normalize_status(:down), do: :down
  defp normalize_status(:error), do: :down
  defp normalize_status(_), do: :unknown

  defp status_dot_class(:ok), do: "bg-cyan-500"
  defp status_dot_class(:warn), do: "bg-slate-400"
  defp status_dot_class(:down), do: "bg-slate-700"
  defp status_dot_class(:unknown), do: "bg-slate-300"

  defp trend_label(value) when value >= 0, do: "+#{round2(value)}%"
  defp trend_label(value), do: "#{round2(value)}%"

  defp format_value(nil), do: "--"

  defp format_value(value) when is_integer(value) do
    value
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(.{3})(?=.)/, "\\1,")
    |> String.reverse()
  end

  defp format_value(value) when is_float(value) do
    rounded = Float.round(value, 2)

    if rounded == trunc(rounded) do
      Integer.to_string(trunc(rounded))
    else
      :erlang.float_to_binary(rounded, decimals: 2)
      |> String.trim_trailing("0")
      |> String.trim_trailing(".")
    end
  end

  defp format_value(value), do: to_string(value)

  defp to_number(value) when is_integer(value), do: value * 1.0
  defp to_number(value) when is_float(value), do: value

  defp to_number(value) when is_binary(value) do
    case Float.parse(value) do
      {number, _rest} -> number
      :error -> 0.0
    end
  end

  defp to_number(_value), do: 0.0

  defp palette(0), do: @accent
  defp palette(1), do: "rgba(3, 182, 212, 0.75)"
  defp palette(2), do: "rgba(3, 182, 212, 0.5)"
  defp palette(3), do: "#334155"
  defp palette(index), do: if(rem(index, 2) == 0, do: "#94a3b8", else: "#475569")

  defp semicircle_points(cx, cy, radius, start_angle, end_angle, steps) when steps <= 1 do
    {sx, sy} = polar_to_cartesian(cx, cy, radius, start_angle)
    {ex, ey} = polar_to_cartesian(cx, cy, radius, end_angle)
    "#{round2(sx)},#{round2(sy)} #{round2(ex)},#{round2(ey)}"
  end

  defp semicircle_points(cx, cy, radius, start_angle, end_angle, steps) do
    Enum.map_join(0..steps, " ", fn idx ->
      angle = start_angle + (end_angle - start_angle) * idx / steps
      {x, y} = polar_to_cartesian(cx, cy, radius, angle)
      "#{round2(x)},#{round2(y)}"
    end)
  end

  defp polar_to_cartesian(cx, cy, radius, angle_degrees) do
    angle_radians = :math.pi() * angle_degrees / 180
    x = cx + radius * :math.cos(angle_radians)
    y = cy + radius * :math.sin(angle_radians)
    {x, y}
  end

  defp clamp(value, min, _max) when value < min, do: min
  defp clamp(value, _min, max) when value > max, do: max
  defp clamp(value, _min, _max), do: value

  defp round2(value), do: Float.round(value * 1.0, 2)
end
