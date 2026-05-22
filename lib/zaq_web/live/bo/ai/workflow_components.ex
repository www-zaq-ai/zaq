defmodule ZaqWeb.Live.BO.AI.WorkflowComponents do
  @moduledoc """
  Shared function components for the Workflows BO pages.

  Used by WorkflowsLive, WorkflowDetailLive, and WorkflowRunLive.
  """
  use Phoenix.Component

  @doc "Status pill for a workflow (draft/active/archived)."
  attr :status, :string, required: true

  def workflow_status_badge(assigns) do
    ~H"""
    <span class={[
      "font-mono text-[0.7rem] px-2 py-0.5 rounded",
      status_class(@status)
    ]}>
      {@status}
    </span>
    """
  end

  @doc "Status pill for a workflow run (pending/running/completed/failed)."
  attr :status, :string, required: true

  def run_status_badge(assigns) do
    ~H"""
    <span class={[
      "font-mono text-[0.7rem] px-2 py-0.5 rounded",
      run_status_class(@status)
    ]}>
      {@status}
    </span>
    """
  end

  @doc "Human-readable duration derived from a run's started_at / finished_at."
  attr :run, :map, required: true
  attr :now, :any, default: nil

  def run_duration(assigns) do
    ~H"""
    <span class="font-mono text-[0.75rem] text-black/60">
      {format_duration(@run, @now)}
    </span>
    """
  end

  @doc """
  Trigger type icon. Shows a clickable run button for manual triggers.

  The `Trigger` schema has no `type` field — display type is derived from
  `event_name` via `trigger_display_type/1`.
  """
  attr :trigger, :map, required: true
  attr :workflow_id, :string, required: true

  def trigger_icon(assigns) do
    assigns = assign(assigns, :display_type, trigger_display_type(assigns.trigger.event_name))

    ~H"""
    <%= if @trigger.enabled and @display_type == "manual" do %>
      <button
        phx-click="run_workflow"
        phx-value-workflow_id={@workflow_id}
        title="Run workflow manually"
        class="inline-flex items-center justify-center w-7 h-7 rounded-full bg-[var(--zaq-color-accent)]/10 text-[var(--zaq-color-accent)] hover:bg-[var(--zaq-color-accent)]/20 transition-colors"
      >
        <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
          <path d="M8 5v14l11-7z" />
        </svg>
      </button>
    <% else %>
      <span
        title={trigger_label(@display_type)}
        class="inline-flex items-center justify-center w-7 h-7 text-black/30"
      >
        <.trigger_type_icon type={@display_type} />
      </span>
    <% end %>
    """
  end

  @doc false
  attr :type, :string, required: true

  def trigger_type_icon(%{type: "manual"} = assigns) do
    ~H"""
    <svg class="w-4 h-4" fill="currentColor" viewBox="0 0 24 24">
      <path d="M8 5v14l11-7z" />
    </svg>
    """
  end

  def trigger_type_icon(%{type: "webhook"} = assigns) do
    ~H"""
    <svg
      class="w-4 h-4"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      viewBox="0 0 24 24"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
      <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
    </svg>
    """
  end

  def trigger_type_icon(%{type: "scheduler"} = assigns) do
    ~H"""
    <svg
      class="w-4 h-4"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      viewBox="0 0 24 24"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <circle cx="12" cy="12" r="10" />
      <polyline points="12 6 12 12 16 14" />
    </svg>
    """
  end

  def trigger_type_icon(%{type: "signal"} = assigns) do
    ~H"""
    <svg
      class="w-4 h-4"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      viewBox="0 0 24 24"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <path d="M18 8A6 6 0 0 0 6 8c0 7-3 9-3 9h18s-3-2-3-9" />
      <path d="M13.73 21a2 2 0 0 1-3.46 0" />
    </svg>
    """
  end

  def trigger_type_icon(assigns) do
    ~H"""
    <svg
      class="w-4 h-4"
      fill="none"
      stroke="currentColor"
      stroke-width="2"
      viewBox="0 0 24 24"
      stroke-linecap="round"
      stroke-linejoin="round"
    >
      <circle cx="12" cy="12" r="10" />
      <path d="M12 8v4m0 4h.01" />
    </svg>
    """
  end

  @doc """
  Renders the workflow DAG as an SVG.

  Pass `step_runs` (list of StepRun structs or maps) to colour each node by
  its execution status. Omit `step_runs` (or pass `[]`) for the static view.
  Handles both struct nodes/edges (detail page) and string-key map nodes/edges
  (run page, from steps_snapshot).
  """
  attr :nodes, :list, required: true
  attr :edges, :list, required: true
  attr :step_runs, :list, default: []

  def workflow_dag(assigns) do
    layout = dag_layout(assigns.nodes, assigns.edges)
    run_idx = Map.new(assigns.step_runs, fn sr -> {nf(sr, "step_name"), sr} end)

    node_renders =
      Enum.map(layout.nodes, fn %{name: name, x: x, y: y, w: w, h: h, is_hitl: is_hitl} ->
        sr = Map.get(run_idx, name)
        {fill, stroke, tc} = dag_node_colors(sr, is_hitl)
        label = if String.length(name) > 17, do: String.slice(name, 0, 14) <> "…", else: name

        %{
          x: x,
          y: y,
          w: w,
          h: h,
          fill: fill,
          stroke: stroke,
          tc: tc,
          label: label,
          is_hitl: is_hitl
        }
      end)

    has_runs = assigns.step_runs != []

    edge_renders =
      Enum.flat_map(layout.edges, fn %{from: from, to: to} ->
        build_edge_render(layout.pos[from], layout.pos[to], run_idx, from, to, has_runs)
      end)

    assigns =
      assigns
      |> assign(:layout, layout)
      |> assign(:node_renders, node_renders)
      |> assign(:edge_renders, edge_renders)

    ~H"""
    <div class="w-full overflow-x-auto flex justify-center">
      <p
        :if={@nodes == []}
        class="font-mono text-[0.75rem] text-black/40 text-center py-8"
      >
        No steps defined.
      </p>
      <svg
        :if={@nodes != []}
        viewBox={"0 0 #{@layout.width} #{@layout.height}"}
        width={@layout.width}
        height={@layout.height}
        xmlns="http://www.w3.org/2000/svg"
      >
        <defs>
          <marker
            id="dag-arr"
            markerWidth="8"
            markerHeight="8"
            refX="6"
            refY="4"
            orient="auto"
          >
            <path d="M1,1 L1,7 L7,4 z" fill="#cbd5e1" />
          </marker>
          <marker
            id="dag-arr-active"
            markerWidth="8"
            markerHeight="8"
            refX="6"
            refY="4"
            orient="auto"
          >
            <path d="M1,1 L1,7 L7,4 z" fill="#22c55e" />
          </marker>
        </defs>

        <path
          :for={e <- @edge_renders}
          d={e.d}
          stroke={e.color}
          stroke-width="1.5"
          fill="none"
          marker-end={if e.active, do: "url(#dag-arr-active)", else: "url(#dag-arr)"}
        />

        <g :for={n <- @node_renders}>
          <rect
            x={n.x}
            y={n.y}
            width={n.w}
            height={n.h}
            rx="8"
            fill={n.fill}
            stroke={n.stroke}
            stroke-width="1.5"
            stroke-dasharray={if n.is_hitl, do: "4 2", else: "none"}
          />
          <text
            x={n.x + div(n.w, 2)}
            y={n.y + div(n.h, 2) + 4}
            text-anchor="middle"
            font-family="ui-monospace, 'Courier New', monospace"
            font-size="11"
            fill={n.tc}
          >
            {n.label}
          </text>
        </g>
      </svg>
    </div>
    """
  end

  @doc "A single structured log entry row from a step run's logs list."
  attr :log, :map, required: true

  def step_log_entry(assigns) do
    ~H"""
    <div class={["flex items-start gap-2 font-mono text-[0.75rem]", log_row_class(@log["level"])]}>
      <span class="flex-shrink-0 w-12 uppercase tracking-wider font-semibold opacity-70">
        {@log["level"]}
      </span>
      <span class="flex-1 break-all">{@log["message"]}</span>
      <span :if={@log["timestamp"]} class="flex-shrink-0 text-black/40 whitespace-nowrap">
        {@log["timestamp"]}
      </span>
    </div>
    """
  end

  # ── Helpers ─────────────────────────────────────────────────────

  # Maps a trigger's event_name to a display type for icon selection.
  # "manual_trigger" is the canonical event_name for manually-fired triggers.
  defp trigger_display_type("manual_trigger"), do: "manual"

  defp trigger_display_type(name) when is_binary(name) do
    cond do
      String.contains?(name, "webhook") -> "webhook"
      String.contains?(name, "schedule") or String.contains?(name, "cron") -> "scheduler"
      String.contains?(name, "signal") -> "signal"
      true -> "event"
    end
  end

  defp trigger_display_type(_), do: "event"

  defp trigger_label("manual"), do: "Manual trigger"
  defp trigger_label("webhook"), do: "Webhook trigger"
  defp trigger_label("scheduler"), do: "Scheduled trigger"
  defp trigger_label("signal"), do: "Signal trigger"
  defp trigger_label(_), do: "Trigger"

  defp status_class("active"), do: "bg-emerald-100 text-emerald-700"
  defp status_class("archived"), do: "bg-black/5 text-black/30"
  defp status_class(_), do: "bg-amber-100 text-amber-700"

  defp run_status_class("completed"), do: "bg-emerald-100 text-emerald-700"
  defp run_status_class("failed"), do: "bg-red-100 text-red-600"
  defp run_status_class("running"), do: "bg-blue-100 text-blue-600"
  defp run_status_class("waiting"), do: "bg-amber-100 text-amber-700"
  defp run_status_class("cancelled"), do: "bg-orange-100 text-orange-600"
  defp run_status_class("paused"), do: "bg-black/5 text-black/50"
  defp run_status_class(_), do: "bg-black/5 text-black/40"

  defp log_row_class("error"), do: "text-red-700"
  defp log_row_class("warn"), do: "text-amber-700"
  defp log_row_class(_), do: "text-black"

  defp format_duration(%{started_at: nil}, _now), do: "—"

  defp format_duration(%{started_at: started_at, finished_at: nil}, now) do
    elapsed(started_at, now || DateTime.utc_now())
  end

  defp format_duration(%{started_at: started_at, finished_at: finished_at}, _now) do
    diff = DateTime.diff(finished_at, started_at, :second)
    format_seconds(diff)
  end

  defp elapsed(started_at, now) do
    diff = DateTime.diff(now, started_at, :second)
    format_seconds(diff) <> "…"
  end

  defp format_seconds(s) when s < 60, do: "#{s}s"
  defp format_seconds(s), do: "#{div(s, 60)}m #{rem(s, 60)}s"

  defp build_edge_render(nil, _, _, _, _, _), do: []
  defp build_edge_render(_, nil, _, _, _, _), do: []

  defp build_edge_render(src, tgt, run_idx, from, to, has_runs) do
    x1 = src.x + div(src.w, 2)
    y1 = src.y + src.h
    x2 = tgt.x + div(tgt.w, 2)
    y2 = tgt.y - 8
    vc = max(16, div(y2 - y1, 2))
    active = has_runs && !is_nil(Map.get(run_idx, from)) && !is_nil(Map.get(run_idx, to))
    color = if active, do: "#22c55e", else: "#cbd5e1"

    [
      %{
        d: "M #{x1},#{y1} C #{x1},#{y1 + vc} #{x2},#{y2 - vc} #{x2},#{y2}",
        color: color,
        active: active
      }
    ]
  end

  # ── DAG layout ──────────────────────────────────────────────────

  @dag_node_w 160
  @dag_node_h 44
  @dag_h_gap 40
  @dag_v_gap 80
  @dag_pad_x 24
  @dag_pad_y 20

  # Returns %{nodes: [%{name,x,y,w,h}], pos: %{name => %{x,y,w,h}}, edges: [%{from,to}], width, height}
  defp dag_layout(raw_nodes, raw_edges) do
    nodes =
      Enum.map(raw_nodes, fn n ->
        %{
          name: nf(n, "name"),
          type: nf(n, "type"),
          index: nf(n, "index") || 0,
          is_hitl: hitl_module?(nf(n, "module"))
        }
      end)

    edges =
      Enum.map(raw_edges, fn e -> %{from: nf(e, "from"), to: nf(e, "to")} end)
      |> Enum.filter(&(&1.from && &1.to))

    if nodes == [] do
      %{nodes: [], pos: %{}, edges: [], width: 200, height: 80}
    else
      levels = assign_dag_levels(nodes, edges)

      by_level =
        nodes
        |> Enum.group_by(&Map.get(levels, &1.name, 0))
        |> Enum.map(fn {level, ns} -> {level, Enum.sort_by(ns, & &1.index)} end)

      max_level = by_level |> Enum.map(fn {l, _} -> l end) |> Enum.max()

      row_widths =
        Map.new(by_level, fn {level, ns} ->
          n = length(ns)
          {level, n * @dag_node_w + max(0, n - 1) * @dag_h_gap}
        end)

      max_row_w = row_widths |> Map.values() |> Enum.max()
      total_w = max_row_w + 2 * @dag_pad_x
      total_h = (max_level + 1) * @dag_node_h + max_level * @dag_v_gap + 2 * @dag_pad_y

      positioned =
        for {level, level_nodes} <- by_level,
            {node, idx} <- Enum.with_index(level_nodes) do
          row_w = Map.get(row_widths, level)

          x =
            @dag_pad_x + div(total_w - 2 * @dag_pad_x - row_w, 2) +
              idx * (@dag_node_w + @dag_h_gap)

          y = @dag_pad_y + level * (@dag_node_h + @dag_v_gap)
          %{name: node.name, x: x, y: y, w: @dag_node_w, h: @dag_node_h, is_hitl: node.is_hitl}
        end

      pos_map = Map.new(positioned, &{&1.name, &1})

      %{nodes: positioned, pos: pos_map, edges: edges, width: total_w, height: total_h}
    end
  end

  # Assigns each node a level = max(parent levels) + 1, processing in index order.
  defp assign_dag_levels(nodes, edges) do
    parents_of =
      Enum.reduce(edges, %{}, fn e, acc ->
        Map.update(acc, e.to, [e.from], &[e.from | &1])
      end)

    nodes
    |> Enum.sort_by(& &1.index)
    |> Enum.reduce(%{}, fn node, levels ->
      parent_levels = Map.get(parents_of, node.name, []) |> Enum.map(&Map.get(levels, &1, 0))
      level = if parent_levels == [], do: 0, else: Enum.max(parent_levels) + 1
      Map.put(levels, node.name, level)
    end)
  end

  # Accepts both atom-key structs (%StepNode{name: …}) and string-key maps (%{"name" => …}).
  defp nf(%{} = m, key) when is_binary(key) do
    Map.get(m, key) || Map.get(m, String.to_existing_atom(key))
  rescue
    _ -> Map.get(m, key)
  end

  defp dag_node_colors(sr, is_hitl)
  defp dag_node_colors(nil, true), do: {"#fffbeb", "#f59e0b", "#92400e"}
  defp dag_node_colors(nil, _), do: {"#f4f4f5", "#d1d5db", "#374151"}
  defp dag_node_colors(%{status: "waiting"}, _), do: {"#fffbeb", "#f59e0b", "#92400e"}
  defp dag_node_colors(%{"status" => "waiting"}, _), do: {"#fffbeb", "#f59e0b", "#92400e"}
  defp dag_node_colors(sr, _), do: dag_node_colors(sr)

  defp dag_node_colors(nil), do: {"#f4f4f5", "#d1d5db", "#374151"}
  defp dag_node_colors(%{status: "completed"}), do: {"#f0fdf4", "#22c55e", "#15803d"}
  defp dag_node_colors(%{status: "failed"}), do: {"#fef2f2", "#ef4444", "#dc2626"}
  defp dag_node_colors(%{status: "running"}), do: {"#eff6ff", "#3b82f6", "#1d4ed8"}
  defp dag_node_colors(%{status: "pending"}), do: {"#f9fafb", "#9ca3af", "#6b7280"}
  defp dag_node_colors(%{"status" => s}), do: dag_node_colors(%{status: s})
  defp dag_node_colors(_), do: {"#f4f4f5", "#d1d5db", "#374151"}

  defp hitl_module?(nil), do: false
  defp hitl_module?(mod) when is_binary(mod), do: String.contains?(mod, "HumanInTheLoop")
  defp hitl_module?(_), do: false
end
