defmodule ZaqWeb.Live.BO.AI.WorkflowComponents do
  @moduledoc """
  Shared function components for the Workflows BO pages.

  Used by WorkflowsLive, WorkflowDetailLive, and WorkflowRunLive.
  """
  use Phoenix.Component

  alias Phoenix.LiveView.JS
  alias ZaqWeb.Live.BO.AI.WorkflowResultHelpers

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

  Batch nodes are rendered with a purple double-border; `map` nodes with a
  teal dashed border; HITL nodes retain their amber dashed style.
  """
  attr :nodes, :list, required: true
  attr :edges, :list, required: true
  attr :step_runs, :list, default: []
  attr :on_node_click, :boolean, default: false
  attr :selected_step, :string, default: nil

  def workflow_dag(assigns) do
    layout = dag_layout(assigns.nodes, assigns.edges)
    run_idx = Map.new(assigns.step_runs, fn sr -> {nf(sr, "step_name"), sr} end)

    node_renders =
      Enum.map(
        layout.nodes,
        fn %{
             name: name,
             x: x,
             y: y,
             w: w,
             h: h,
             is_hitl: is_hitl,
             is_batch: is_batch,
             is_map: is_map,
             is_start: is_start,
             inner: inner,
             separator_y: separator_y
           } ->
          sr = Map.get(run_idx, name)
          # A `map`/`Batch` node gets the iteration visual treatment (teal, dashed,
          # vertical body-step stack) since it is the iteration primitive. The
          # virtual `start` origin gets its own indigo "trigger" styling.
          {fill, stroke, tc} = dag_node_colors(sr, is_hitl, is_batch, is_map, is_start)
          label = if String.length(name) > 17, do: String.slice(name, 0, 14) <> "…", else: name

          %{
            name: name,
            x: x,
            y: y,
            w: w,
            h: h,
            fill: fill,
            stroke: stroke,
            tc: tc,
            label: label,
            is_hitl: is_hitl,
            is_batch: is_batch,
            is_map: is_map,
            is_start: is_start,
            inner: inner,
            separator_y: separator_y
          }
        end
      )

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
          <%!-- Selected node highlight ring --%>
          <rect
            :if={@on_node_click and n.name == @selected_step}
            x={n.x - 4}
            y={n.y - 4}
            width={n.w + 8}
            height={n.h + 8}
            rx="12"
            fill="none"
            stroke="#03b6d4"
            stroke-width="2"
            opacity="0.8"
          />
          <%!-- Batch: inner offset rect for double-border effect --%>
          <rect
            :if={n.is_batch}
            x={n.x + 4}
            y={n.y + 4}
            width={n.w - 8}
            height={n.h - 8}
            rx="5"
            fill="none"
            stroke={n.stroke}
            stroke-width="1"
            opacity="0.35"
          />
          <%!-- Main node rect --%>
          <rect
            x={n.x}
            y={n.y}
            width={n.w}
            height={n.h}
            rx="8"
            fill={n.fill}
            stroke={n.stroke}
            stroke-width="1.5"
            stroke-dasharray={
              cond do
                n.is_hitl -> "4 2"
                n.is_map -> "6 2"
                true -> "none"
              end
            }
          />
          <%!-- Type badge text for batch / map --%>
          <text
            :if={n.is_batch or n.is_map}
            x={n.x + n.w - 6}
            y={n.y + 11}
            text-anchor="end"
            font-family="ui-monospace, 'Courier New', monospace"
            font-size="7"
            fill={n.stroke}
            opacity="0.7"
          >
            {if n.is_batch, do: "BATCH", else: "MAP"}
          </text>
          <%!-- Node label (centred in header band) --%>
          <text
            x={n.x + div(n.w, 2)}
            y={n.y + div(n.separator_y, 2) + 4}
            text-anchor="middle"
            font-family="ui-monospace, 'Courier New', monospace"
            font-size="11"
            fill={n.tc}
          >
            {n.label}
          </text>
          <%!-- Separator between header and inner section --%>
          <line
            :if={n.inner.h_extra > 0}
            x1={n.x + 8}
            y1={n.y + n.separator_y}
            x2={n.x + n.w - 8}
            y2={n.y + n.separator_y}
            stroke={n.stroke}
            stroke-width="0.5"
            opacity="0.3"
          />
          <%!-- Batch: post-process section separator label --%>
          <line
            :if={n.inner.post_section_y}
            x1={n.x + 8}
            y1={n.y + n.separator_y + n.inner.post_section_y}
            x2={n.x + n.w - 8}
            y2={n.y + n.separator_y + n.inner.post_section_y}
            stroke={n.stroke}
            stroke-width="0.5"
            stroke-dasharray="4 2"
            opacity="0.4"
          />
          <text
            :if={n.inner.post_section_y}
            x={n.x + div(n.w, 2)}
            y={n.y + n.separator_y + n.inner.post_section_y + 13}
            text-anchor="middle"
            font-family="ui-monospace, 'Courier New', monospace"
            font-size="7"
            fill={n.stroke}
            opacity="0.6"
          >
            POST PROCESS
          </text>
          <%!-- Batch: sub-nodes (process + post_process pipeline steps) --%>
          <g :for={sn <- n.inner.sub_nodes}>
            <rect
              x={n.x + 8}
              y={n.y + n.separator_y + sn.y_offset}
              width={n.w - 16}
              height={sn.h}
              rx="5"
              fill="#f4f4f5"
              stroke="#d1d5db"
              stroke-width="1"
              stroke-dasharray="none"
            />
            <text
              x={n.x + 14}
              y={n.y + n.separator_y + sn.y_offset + 17}
              font-family="ui-monospace, 'Courier New', monospace"
              font-size="10"
              fill="#374151"
            >
              {sn.sub_label}
            </text>
            <%!-- Iterate sub-node: separator + full-size stacked pipeline nodes --%>
            <line
              :if={sn.mini_nodes != []}
              x1={n.x + 12}
              y1={n.y + n.separator_y + sn.y_offset + 24}
              x2={n.x + n.w - 12}
              y2={n.y + n.separator_y + sn.y_offset + 24}
              stroke="#0ea5e9"
              stroke-width="0.5"
              opacity="0.4"
            />
            <g :if={sn.mini_nodes != []}>
              <g :for={mn <- sn.mini_nodes}>
                <% node_y = n.y + n.separator_y + sn.y_offset + 24 + mn.y_in_section %>
                <% node_x = n.x + 12 %>
                <% node_w = n.w - 24 %>
                <rect
                  x={node_x}
                  y={node_y}
                  width={node_w}
                  height={36}
                  rx="5"
                  fill="#f0f9ff"
                  stroke="#0ea5e9"
                  stroke-width="1"
                />
                <text
                  x={node_x + div(node_w, 2)}
                  y={node_y + 22}
                  text-anchor="middle"
                  font-family="ui-monospace, 'Courier New', monospace"
                  font-size="10"
                  fill="#0369a1"
                >
                  {mn.label}
                </text>
                <line
                  :if={mn.has_arrow_below}
                  x1={node_x + div(node_w, 2)}
                  y1={node_y + 36}
                  x2={node_x + div(node_w, 2)}
                  y2={node_y + 46}
                  stroke="#0ea5e9"
                  stroke-width="1.5"
                  marker-end="url(#dag-arr)"
                />
              </g>
            </g>
          </g>
          <%!-- Standalone iterate: full-size stacked pipeline nodes --%>
          <g :if={n.inner.type == :iterate and n.inner.mini_nodes != []}>
            <g :for={mn <- n.inner.mini_nodes}>
              <% node_y = n.y + n.separator_y + 4 + mn.y_in_section %>
              <% node_x = n.x + 12 %>
              <% node_w = n.w - 24 %>
              <rect
                x={node_x}
                y={node_y}
                width={node_w}
                height={36}
                rx="5"
                fill="#f0f9ff"
                stroke="#0ea5e9"
                stroke-width="1"
              />
              <text
                x={node_x + div(node_w, 2)}
                y={node_y + 22}
                text-anchor="middle"
                font-family="ui-monospace, 'Courier New', monospace"
                font-size="10"
                fill="#0369a1"
              >
                {mn.label}
              </text>
              <line
                :if={mn.has_arrow_below}
                x1={node_x + div(node_w, 2)}
                y1={node_y + 36}
                x2={node_x + div(node_w, 2)}
                y2={node_y + 46}
                stroke="#0ea5e9"
                stroke-width="1.5"
                marker-end="url(#dag-arr)"
              />
            </g>
          </g>
          <%!-- Clickable overlay — captures click for the whole node --%>
          <rect
            :if={@on_node_click}
            x={n.x}
            y={n.y}
            width={n.w}
            height={n.h}
            rx="8"
            fill="transparent"
            class="cursor-pointer"
            phx-click="select_step"
            phx-value-step_name={n.name}
          />
        </g>
      </svg>
    </div>
    """
  end

  @doc """
  Detail card for the virtual `start` origin node. Shows the run's trigger
  payload — the `source_event` input that seeds the `start` namespace — since
  `start` has no `StepRun` of its own.
  """
  attr :run, :map, required: true

  def start_input_card(assigns) do
    assigns =
      assigns
      |> assign(:input, source_event_input(assigns.run))
      |> assign(:trigger_type, source_event_trigger_type(assigns.run))

    ~H"""
    <div class="bg-white rounded-xl border border-black/[0.08] overflow-hidden">
      <div class="flex items-center justify-between px-5 py-3 border-b border-black/[0.06] bg-indigo-50/60">
        <div class="flex items-center gap-3">
          <span class="font-mono text-[0.85rem] font-semibold text-indigo-700">start</span>
          <span
            :if={@trigger_type}
            class="font-mono text-[0.62rem] text-indigo-500 uppercase tracking-wider"
          >
            {@trigger_type} trigger
          </span>
        </div>
      </div>

      <div class="px-5 py-3">
        <p class="font-mono text-[0.65rem] font-semibold text-black/40 uppercase tracking-wider mb-2">
          Trigger input
        </p>
        <p
          :if={map_size(@input) == 0}
          class="font-mono text-[0.8rem] text-black/40 py-2"
        >
          No trigger input recorded.
        </p>
        <ZaqWeb.Components.JsonTree.json_tree
          :if={map_size(@input) > 0}
          id="jt-start-input"
          data={@input}
        />
      </div>
    </div>
    """
  end

  # The trigger payload that seeds the run's `start` namespace, read from the
  # persisted `source_event.assigns.input` (atom keys, with a string fallback).
  defp source_event_input(%{source_event: %{assigns: assigns}}) when is_map(assigns) do
    case Map.get(assigns, :input) || Map.get(assigns, "input") do
      input when is_map(input) -> input
      _ -> %{}
    end
  end

  defp source_event_input(_run), do: %{}

  defp source_event_trigger_type(%{source_event: %{assigns: assigns}}) when is_map(assigns) do
    case Map.get(assigns, :trigger_type) || Map.get(assigns, "trigger_type") do
      nil -> nil
      "" -> nil
      type -> to_string(type)
    end
  end

  defp source_event_trigger_type(_run), do: nil

  @doc "A single structured log entry row from a step run's logs list."
  attr :log, :map, required: true

  def step_log_entry(assigns) do
    ~H"""
    <div class="flex items-center gap-3 font-mono text-[0.72rem] leading-snug">
      <span class={[
        "flex-shrink-0 text-[0.6rem] font-bold uppercase tracking-wider",
        log_event_class(@log["event"])
      ]}>
        {@log["event"]}
      </span>
      <span :if={not is_nil(@log["duration_ms"])} class="flex-shrink-0 tabular-nums text-black/40">
        {@log["duration_ms"]}ms
      </span>
      <% extra = log_entry_extra(@log) %>
      <span :if={extra != ""} class="text-black/50 truncate">{extra}</span>
    </div>
    """
  end

  @doc """
  Renders a step card for a Batch node.

  Shows:
  - Live batch progress bar (when running) via `batch_progress`
  - Live iterate-inside-batch item progress (when running) via `iterate_progress`
  - Inner process pipeline step names as connected chips
  - Per-batch result summary (collapsible, when completed)
  - Full output JSON (collapsible)

  `node_params` should be the node's `params` map from `steps_snapshot` —
  used to read the `process` and `post_process` pipeline step names.
  """
  attr :step, :map, required: true
  attr :batch_progress, :map, default: nil
  attr :step_runs, :list, default: []
  attr :node_params, :map, default: %{}
  attr :now, :any, default: nil

  def batch_step_card(assigns) do
    assigns =
      assign(assigns,
        delivery_label: batch_delivery_label(assigns.node_params),
        fork_groups: fork_step_groups(assigns.step_runs, assigns.step.step_name)
      )

    ~H"""
    <div class="bg-white rounded-xl border border-purple-200 overflow-hidden shadow-[0_0_0_1px_rgb(233,213,255,0.5)]">
      <%!-- Header --%>
      <div class="flex items-center justify-between px-5 py-3 bg-purple-50 border-b border-purple-100">
        <div class="flex items-center gap-3">
          <span class="font-mono text-[0.62rem] font-bold text-purple-500 uppercase tracking-wider bg-purple-100 px-1.5 py-0.5 rounded leading-none">
            BATCH
          </span>
          <span
            :if={@delivery_label}
            class="font-mono text-[0.6rem] text-purple-600/80 bg-purple-50 px-1.5 py-0.5 rounded border border-purple-200 leading-none"
          >
            {@delivery_label}
          </span>
          <span class="font-mono text-[0.72rem] text-black/40 w-5 text-right tabular-nums">
            {@step.step_index + 1}
          </span>
          <span class="font-mono text-[0.85rem] font-semibold text-black">
            {@step.step_name}
          </span>
        </div>
        <div class="flex items-center gap-3">
          <.run_duration run={@step} now={@now} />
          <.run_status_badge status={@step.status} />
        </div>
      </div>

      <%!-- Batch progress bar (always visible while running or after completion) --%>
      <% progress = batch_display_progress(@step, @batch_progress, @fork_groups) %>
      <div :if={progress != nil} class="px-5 py-4 border-b border-purple-100">
        <div class="flex items-center justify-between mb-2">
          <span class="font-mono text-[0.68rem] font-semibold text-purple-600 uppercase tracking-wider">
            Batches
          </span>
          <span class="font-mono text-[0.75rem] text-black/60 flex items-center gap-2">
            <%= if progress.total > 0 do %>
              {progress.current} / {progress.total}
              <span :if={progress.ok > 0} class="text-emerald-600">✓ {progress.ok}</span>
              <span :if={progress.errors > 0} class="text-red-500">✗ {progress.errors}</span>
            <% else %>
              <%= if progress.ok > 0 or progress.errors > 0 do %>
                <span class="text-black/50">{progress.current} done</span>
                <span :if={progress.ok > 0} class="text-emerald-600">✓ {progress.ok}</span>
                <span :if={progress.errors > 0} class="text-red-500">✗ {progress.errors}</span>
              <% else %>
                <span class="text-black/40 italic">initializing…</span>
              <% end %>
            <% end %>
          </span>
        </div>
        <div class="w-full bg-black/5 rounded-full h-2 overflow-hidden">
          <%= if progress.total > 0 do %>
            <div
              class="bg-purple-400 h-2 rounded-full transition-all duration-300"
              style={"width: #{batch_pct(progress)}%"}
            />
          <% else %>
            <div class="bg-purple-200 h-2 rounded-full w-full animate-pulse" />
          <% end %>
        </div>
      </div>

      <%!-- Inner pipeline visualization (process + optional iterate + post) --%>
      <% process_names = get_inner_step_names(@node_params, "process") %>
      <% post_names = get_inner_step_names(@node_params, "post_process") %>
      <% live_phase = @batch_progress && @step.status == "running" && Map.get(@batch_progress, :phase) %>
      <% current_step = @batch_progress && Map.get(@batch_progress, :current_step) %>
      <div :if={process_names != []} class="px-5 py-3 border-b border-purple-100 space-y-1.5">
        <%!-- Process lane --%>
        <div class={[
          "rounded-lg px-3 py-2 transition-colors",
          cond do
            live_phase == :process -> "bg-purple-50 ring-1 ring-purple-300"
            live_phase == :post_process -> "opacity-60"
            true -> ""
          end
        ]}>
          <div class="flex items-center flex-wrap gap-1.5">
            <span class={[
              "font-mono text-[0.6rem] font-bold uppercase tracking-wider mr-1 transition-colors",
              cond do
                live_phase == :process -> "text-purple-500"
                live_phase == :post_process -> "text-black/20"
                true -> "text-black/30"
              end
            ]}>
              Process
            </span>
            <span
              :if={live_phase == :process}
              class="inline-block w-1.5 h-1.5 rounded-full bg-purple-400 animate-pulse mr-0.5"
            />
            <%= for {name, i} <- Enum.with_index(process_names) do %>
              <% chip_state =
                cond do
                  live_phase == :post_process -> :done
                  live_phase == :process and is_integer(current_step) and i < current_step -> :done
                  live_phase == :process and is_integer(current_step) and i == current_step -> :active
                  live_phase == :process -> :pending
                  true -> :idle
                end %>
              <span class={[
                "inline-flex items-center gap-1 font-mono text-[0.72rem] px-2 py-0.5 rounded-full border transition-colors",
                case chip_state do
                  :done -> "text-emerald-700 bg-emerald-100 border-emerald-300"
                  :active -> "text-purple-700 bg-purple-100 border-purple-400"
                  :pending -> "text-black/30 bg-black/[0.03] border-black/[0.06]"
                  :idle -> "text-purple-700 bg-purple-50 border-purple-200"
                end
              ]}>
                <span
                  :if={chip_state == :active}
                  class="inline-block w-1.5 h-1.5 rounded-full bg-purple-400 animate-pulse"
                />
                <span :if={chip_state == :done} class="text-emerald-500 text-[0.6rem] leading-none">
                  ✓
                </span>
                {name}
              </span>
            <% end %>
          </div>
        </div>
        <%!-- Post-process lane --%>
        <div
          :if={post_names != []}
          class={[
            "rounded-lg px-3 py-2 transition-colors",
            if(live_phase == :post_process, do: "bg-emerald-50 ring-1 ring-emerald-300", else: "")
          ]}
        >
          <div class="flex items-center flex-wrap gap-1.5">
            <span class={[
              "font-mono text-[0.6rem] font-bold uppercase tracking-wider mr-1 transition-colors",
              if(live_phase == :post_process, do: "text-emerald-600", else: "text-black/30")
            ]}>
              Post
            </span>
            <span
              :if={live_phase == :post_process}
              class="inline-block w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse mr-0.5"
            />
            <%= for {name, i} <- Enum.with_index(post_names) do %>
              <% chip_state =
                cond do
                  live_phase == :post_process and is_integer(current_step) and i < current_step ->
                    :done

                  live_phase == :post_process and is_integer(current_step) and i == current_step ->
                    :active

                  live_phase == :post_process ->
                    :pending

                  true ->
                    :idle
                end %>
              <span class={[
                "inline-flex items-center gap-1 font-mono text-[0.72rem] px-2 py-0.5 rounded-full border transition-colors",
                case chip_state do
                  :done -> "text-emerald-700 bg-emerald-100 border-emerald-300"
                  :active -> "text-emerald-700 bg-emerald-100 border-emerald-400"
                  :pending -> "text-black/30 bg-black/[0.03] border-black/[0.06]"
                  :idle -> "text-black/50 bg-black/[0.03] border-black/[0.08]"
                end
              ]}>
                <span
                  :if={chip_state == :active}
                  class="inline-block w-1.5 h-1.5 rounded-full bg-emerald-400 animate-pulse"
                />
                <span :if={chip_state == :done} class="text-emerald-500 text-[0.6rem] leading-none">
                  ✓
                </span>
                {name}
              </span>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Logs --%>
      <div :if={@step.logs != []} class="px-5 py-3 border-b border-purple-100 space-y-1">
        <p class="font-mono text-[0.65rem] font-semibold text-black/40 uppercase tracking-wider mb-2">
          Logs
        </p>
        <.step_log_entry :for={log <- @step.logs} log={log} />
      </div>

      <%!-- Input (collapsible) --%>
      <div
        :if={not is_nil(@step.input) and map_size(@step.input) > 0}
        class="border-b border-purple-100"
      >
        <button
          type="button"
          phx-click={
            JS.toggle(to: "#batch-input-#{@step.id}")
            |> JS.toggle_class("rotate-90", to: "#batch-in-chevron-#{@step.id}")
          }
          class="w-full px-5 py-3 cursor-pointer flex items-center gap-2 select-none hover:bg-black/[0.01] transition-colors"
        >
          <span class="font-mono text-[0.65rem] font-semibold text-black/40 uppercase tracking-wider">
            Input
          </span>
          <svg
            id={"batch-in-chevron-#{@step.id}"}
            class="w-3 h-3 text-black/30 transition-transform"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
          </svg>
        </button>
        <div id={"batch-input-#{@step.id}"} phx-update="ignore" style="display:none" class="px-5 pb-3">
          <ZaqWeb.Components.JsonTree.json_tree id={"jt-batch-in-#{@step.id}"} data={@step.input} />
        </div>
      </div>

      <%!-- Full output (collapsible) --%>
      <% step_output = clean_results(@step.results) %>
      <div :if={@step.status in ["completed", "waiting"] and map_size(step_output) > 0}>
        <button
          type="button"
          phx-click={
            JS.toggle(to: "#batch-output-#{@step.id}")
            |> JS.toggle_class("rotate-90", to: "#batch-out-chevron-#{@step.id}")
          }
          class="w-full px-5 py-3 cursor-pointer flex items-center gap-2 select-none hover:bg-black/[0.01] transition-colors"
        >
          <span class="font-mono text-[0.65rem] font-semibold text-black/40 uppercase tracking-wider">
            Full Output
          </span>
          <svg
            id={"batch-out-chevron-#{@step.id}"}
            class="w-3 h-3 text-black/30 transition-transform"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
          </svg>
        </button>
        <div
          id={"batch-output-#{@step.id}"}
          phx-update="ignore"
          style="display:none"
          class="px-5 pb-3"
        >
          <ZaqWeb.Components.JsonTree.json_tree id={"jt-batch-#{@step.id}"} data={step_output} />
        </div>
      </div>

      <%!-- Error --%>
      <div :if={@step.status == "failed" and @step.errors != nil} class="px-5 py-3 bg-red-50">
        <p class="font-mono text-[0.65rem] font-semibold text-red-500 uppercase tracking-wider mb-2">
          Error
        </p>
        <pre class="font-mono text-[0.75rem] text-red-700 whitespace-pre-wrap break-all">{inspect(@step.errors, pretty: true)}</pre>
      </div>

      <%!-- Per-batch runs: each batch's StepRuns, grouped by index, with logs --%>
      <.fork_run_list :if={@fork_groups != []} step={@step} groups={@fork_groups} now={@now} />
    </div>
    """
  end

  @doc """
  Renders the aggregate card for a `map` node run.

  The aggregate `StepRun` (named after the map node) carries the
  `%{"results", "errors", "count"}` summary written by `MapCollect`. This card
  surfaces the ok/failed counts and, where they exist, the per-fork failure rows
  (`<node>/<step>[i]` StepRuns with a `failed`/`failed_fatal` status) drawn from
  `step_runs`, so a user sees exactly which item failed and why.
  """
  attr :step, :map, required: true
  attr :step_runs, :list, default: []
  attr :node_params, :map, default: %{}
  attr :now, :any, default: nil

  def map_step_card(assigns) do
    results = assigns.step.results || %{}
    ok_count = results |> Map.get("results", []) |> length()
    errors = Map.get(results, "errors", [])

    assigns =
      assign(assigns,
        ok_count: ok_count,
        failed_count: length(errors),
        errors: errors,
        fork_groups: fork_step_groups(assigns.step_runs, assigns.step.step_name),
        body_names: get_inner_step_names(assigns.node_params, "body"),
        post_names: get_inner_step_names(assigns.node_params, "post_process")
      )

    ~H"""
    <div class="bg-white rounded-xl border border-sky-200 overflow-hidden shadow-[0_0_0_1px_rgb(186,230,253,0.5)]">
      <%!-- Header --%>
      <div class="flex items-center justify-between px-5 py-3 bg-sky-50 border-b border-sky-100">
        <div class="flex items-center gap-3">
          <span class="font-mono text-[0.72rem] text-black/40 w-5 text-right tabular-nums">
            {@step.step_index + 1}
          </span>
          <span class="font-mono text-[0.85rem] font-semibold text-black">{@step.step_name}</span>
          <span class="font-mono text-[0.6rem] font-bold uppercase tracking-wider text-sky-600">
            map
          </span>
        </div>
        <div class="flex items-center gap-3">
          <.run_duration run={@step} now={@now} />
          <.run_status_badge status={@step.status} />
        </div>
      </div>

      <%!-- Per-item body pipeline (run once per item) --%>
      <div :if={@body_names != []} class="px-5 py-3 border-b border-sky-100 space-y-2">
        <p class="font-mono text-[0.6rem] font-bold uppercase tracking-wider text-sky-500">
          Per item
        </p>
        <div class="flex items-center flex-wrap gap-1.5">
          <%= for {name, i} <- Enum.with_index(@body_names) do %>
            <span
              :if={i > 0}
              class="font-mono text-[0.7rem] text-black/30"
            >
              →
            </span>
            <span class="font-mono text-[0.72rem] px-2 py-0.5 rounded bg-sky-50 text-sky-700 border border-sky-200">
              {name}
            </span>
          <% end %>
        </div>
        <div :if={@post_names != []} class="flex items-center flex-wrap gap-1.5">
          <span class="font-mono text-[0.6rem] font-bold uppercase tracking-wider text-black/30 mr-1">
            then
          </span>
          <%= for name <- @post_names do %>
            <span class="font-mono text-[0.72rem] px-2 py-0.5 rounded bg-black/[0.03] text-black/60 border border-black/10">
              {name}
            </span>
          <% end %>
        </div>
      </div>

      <%!-- Aggregate ok / failed counts --%>
      <div class="flex items-center gap-4 px-5 py-3 border-b border-sky-100">
        <span class="font-mono text-[0.78rem] text-emerald-600" data-role="map-ok-count">
          ✓ {@ok_count} ok
        </span>
        <span class="font-mono text-[0.78rem] text-red-600" data-role="map-failed-count">
          ✗ {@failed_count} failed
        </span>
      </div>

      <%!-- Per-batch runs: every batch's StepRuns, grouped by index, with status + logs --%>
      <.fork_run_list :if={@fork_groups != []} step={@step} groups={@fork_groups} now={@now} />
    </div>
    """
  end

  # Pulls a short failure reason out of a per-fork StepRun's `errors` map.
  defp map_fork_reason(%{errors: %{} = errors}),
    do: Map.get(errors, "reason") || Map.get(errors, :reason) || "failed"

  defp map_fork_reason(_), do: "failed"

  attr :step, :map, required: true
  attr :groups, :list, required: true
  attr :now, :any, default: nil

  @doc """
  Collapsible list of a fan-out (`Batch`/`map`) node's per-fork `StepRun` rows —
  every chunk/item, success or failure, each with its own status, duration, and
  logs. This is the per-chunk/per-item log visibility surface.

  Rows are **grouped by fan-out index** (`[i]`): one unit's body-step rows are
  shown together (in execution order), so a reader follows a single item/chunk
  top-to-bottom rather than seeing all `check_active[*]` then all
  `check_email_state[*]`.
  """
  def fork_run_list(assigns) do
    ~H"""
    <div class="border-t border-black/[0.06]">
      <button
        type="button"
        phx-click={
          JS.toggle(to: "#forks-#{@step.id}")
          |> JS.toggle_class("rotate-90", to: "#forks-chev-#{@step.id}")
        }
        class="w-full px-5 py-3 cursor-pointer flex items-center gap-2 select-none hover:bg-black/[0.01] transition-colors"
      >
        <span class="font-mono text-[0.65rem] font-semibold text-black/40 uppercase tracking-wider">
          Per-batch runs ({length(@groups)})
        </span>
        <svg
          id={"forks-chev-#{@step.id}"}
          class="w-3 h-3 text-black/30 transition-transform"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
        </svg>
      </button>
      <div id={"forks-#{@step.id}"} style="display:none" class="divide-y divide-black/[0.06]">
        <div :for={{idx, rows} <- @groups} class="px-5 py-3" data-role="fork-group">
          <p class="font-mono text-[0.6rem] font-bold uppercase tracking-wider text-black/35 mb-2">
            {fork_group_label(idx)}
          </p>
          <div class="space-y-2.5">
            <div :for={fork <- rows} data-role="fork-run">
              <div class="flex items-center justify-between gap-3">
                <span class="font-mono text-[0.78rem] font-semibold text-black/80 truncate">
                  {fork.step_name}
                </span>
                <div class="flex items-center gap-3 shrink-0">
                  <.run_duration run={fork} now={@now} />
                  <.run_status_badge status={fork.status} />
                </div>
              </div>
              <div :if={fork.logs not in [nil, []]} class="mt-1.5 space-y-1">
                <.step_log_entry :for={log <- fork.logs} log={log} />
              </div>
              <p :if={fork_error_reason(fork)} class="mt-1 font-mono text-[0.72rem] text-red-600">
                {fork_error_reason(fork)}
              </p>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp fork_group_label(idx) when is_integer(idx) and idx >= 0, do: "Batch ##{idx}"
  defp fork_group_label(_), do: "Other"

  # Per-fork StepRun rows for a fan-out node, grouped by fan-out index (`[i]`).
  # Returns `[{index, [rows]}]` sorted by index, each group ordered by execution
  # start so a single unit reads top-to-bottom in pipeline order.
  defp fork_step_groups(step_runs, step_name) do
    step_runs
    |> Enum.filter(&String.starts_with?(&1.step_name, step_name <> "/"))
    |> Enum.group_by(&fork_index/1)
    |> Enum.sort_by(fn {idx, _rows} -> idx end)
    |> Enum.map(fn {idx, rows} -> {idx, Enum.sort_by(rows, &fork_sort_key/1)} end)
  end

  # Extracts the trailing fan-out index from a fork step name (`<node>/<step>[i]`).
  defp fork_index(%{step_name: name}) when is_binary(name) do
    case Regex.run(~r/\[(\d+)\]$/, name) do
      [_, i] -> String.to_integer(i)
      _ -> -1
    end
  end

  defp fork_index(_), do: -1

  # Orders rows within a fork by execution start (chronological); rows without a
  # start time sort last, tie-broken by step name for stability.
  defp fork_sort_key(%{started_at: %DateTime{} = dt} = sr),
    do: {0, DateTime.to_unix(dt, :microsecond), sr.step_name}

  defp fork_sort_key(%{step_name: name}), do: {1, 0, name}

  defp fork_error_reason(%{status: s} = sr) when s in ["failed", "failed_fatal"],
    do: map_fork_reason(sr)

  defp fork_error_reason(_), do: nil

  # Human label for a Batch node's delivery mode, shown next to the BATCH badge.
  defp batch_delivery_label(params) when is_map(params) do
    case Map.get(params, "delivery") || Map.get(params, :delivery) || "list" do
      "item" ->
        "per item"

      "list" ->
        case Map.get(params, "batch_size") || Map.get(params, :batch_size) do
          n when is_integer(n) -> "per batch · size #{n}"
          _ -> "per batch"
        end

      _ ->
        nil
    end
  end

  defp batch_delivery_label(_), do: nil

  # ── Public detection helpers (used by WorkflowRunLive for node_info) ──────────

  @doc "Returns true if the module string is the Batch action."
  def batch_module?(nil), do: false
  def batch_module?(mod) when is_binary(mod), do: String.contains?(mod, "Tools.Workflow.Batch")
  def batch_module?(_), do: false

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
  defp run_status_class("interrupted"), do: "bg-yellow-100 text-yellow-700"
  defp run_status_class(_), do: "bg-black/5 text-black/40"

  defp log_event_class(event) when event in ["step_failed", "chunk_error", "item_error"],
    do: "text-red-600"

  defp log_event_class(_), do: "text-black/50"

  defp log_entry_extra(log) do
    ~w(index results errors reason)
    |> Enum.flat_map(fn k ->
      case Map.get(log, k) do
        nil -> []
        v -> ["#{k}: #{v}"]
      end
    end)
    |> Enum.join("  ")
  end

  defp format_duration(%{started_at: nil}, _now), do: "—"

  defp format_duration(%{started_at: s, finished_at: nil} = run, now) do
    status = Map.get(run, :status) || Map.get(run, "status")
    format_live_duration(status, s, run, now)
  end

  defp format_duration(%{started_at: s, finished_at: f}, _now),
    do: format_seconds(DateTime.diff(f, s, :second))

  # Active runs: show a growing elapsed timer with "…" suffix.
  defp format_live_duration(status, started_at, _run, now)
       when status in ["pending", "running"],
       do: elapsed(started_at, now || DateTime.utc_now())

  # Paused runs: freeze at updated_at (the moment pause was recorded) so the
  # display does not grow on page refreshes where @now is set to mount time.
  defp format_live_duration("paused", started_at, run, now) do
    ref = Map.get(run, :updated_at) || Map.get(run, "updated_at") || now || DateTime.utc_now()
    format_seconds(DateTime.diff(ref, started_at, :second))
  end

  # All other terminal statuses with no finished_at: show diff against @now.
  defp format_live_duration(_status, started_at, _run, now),
    do: format_seconds(DateTime.diff(now || DateTime.utc_now(), started_at, :second))

  defp elapsed(started_at, now) do
    diff = DateTime.diff(now, started_at, :second)
    format_seconds(diff) <> "…"
  end

  defp format_seconds(s) when s == 0, do: "< 1s"
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

  # ── Batch / Iterate component helpers ────────────────────────────

  # Returns a normalised progress map for rendering, or nil if no progress.
  # `live_progress` is the live broadcast map; `step` is the step_run; `fork_groups`
  # are the per-batch fork rows. When running, we prefer live_progress, else derive
  # the completed/failed counts live from the fork rows (the total is unknown until
  # the run finishes, so `total: 0` keeps the bar indeterminate). When done, we
  # derive everything from step.results.
  defp batch_display_progress(step, live_progress, fork_groups) do
    cond do
      step.status == "running" and live_progress != nil ->
        %{
          current: live_progress.current_chunk,
          total: live_progress.total_chunks,
          ok: Map.get(live_progress, :successful_chunks, 0),
          errors: Map.get(live_progress, :failed_chunks, 0)
        }

      step.status == "running" ->
        {ok, errors} = fork_terminal_counts(fork_groups)
        %{current: ok + errors, total: 0, ok: ok, errors: errors}

      step.status in ["completed", "failed"] ->
        progress_from_results(step.results)

      true ->
        nil
    end
  end

  # Counts batches (forks) that have reached a terminal state, by inspecting each
  # fork group's last (chronologically) row. A still-running batch's last row is
  # `"running"` and is not counted, so the tally reflects completed iterations.
  defp fork_terminal_counts(fork_groups) do
    Enum.reduce(fork_groups, {0, 0}, fn {_idx, rows}, {ok, err} ->
      case List.last(rows) do
        %{status: "completed"} -> {ok + 1, err}
        %{status: s} when s in ["failed", "failed_fatal"] -> {ok, err + 1}
        _ -> {ok, err}
      end
    end)
  end

  # Derives a progress summary from a completed step's results map.
  defp progress_from_results(results) do
    ok = results_list(results)
    err = errors_list(results)
    total = length(ok) + length(err)
    if total > 0, do: %{current: total, total: total, ok: length(ok), errors: length(err)}
  end

  defp batch_pct(%{current: c, total: t}) when t > 0, do: min(100, round(c / t * 100))
  defp batch_pct(_), do: 0

  # Returns step names from a nested inline params list (process/post_process/pipeline).
  defp get_inner_step_names(params, key) when is_map(params) do
    steps = Map.get(params, key) || Map.get(params, String.to_existing_atom(key)) || []

    Enum.map(steps, fn step ->
      Map.get(step, "name") || Map.get(step, :name) || "?"
    end)
  rescue
    _ -> []
  end

  defp get_inner_step_names(_, _), do: []

  # Strips cascade keys from results before rendering in JsonTree.
  defp clean_results(results), do: WorkflowResultHelpers.clean_results(results)

  defp results_list(nil), do: []
  defp results_list(r) when is_map(r), do: Map.get(r, "results", Map.get(r, :results, []))
  defp results_list(_), do: []

  defp errors_list(nil), do: []
  defp errors_list(r) when is_map(r), do: Map.get(r, "errors", Map.get(r, :errors, []))
  defp errors_list(_), do: []

  # ── DAG layout ──────────────────────────────────────────────────

  @dag_node_w 220
  @dag_node_h 44
  @dag_h_gap 40
  @dag_v_gap 80
  @dag_pad_x 24
  @dag_pad_y 20
  # Full-size inner nodes (iterate pipeline steps rendered as proper nodes, stacked vertically)
  @full_node_h 36
  @full_node_gap 10

  # Returns %{nodes: [%{name,x,y,w,h}], pos: %{name => %{x,y,w,h}}, edges: [%{from,to}], width, height}
  defp dag_layout(raw_nodes, raw_edges) do
    nodes =
      Enum.map(raw_nodes, fn n ->
        mod = nf(n, "module")

        %{
          name: nf(n, "name"),
          type: nf(n, "type"),
          index: nf(n, "index") || 0,
          is_hitl: hitl_module?(mod),
          is_batch: batch_module?(mod),
          is_map: nf(n, "type") == "map",
          is_start: false,
          params: nf(n, "params") || %{}
        }
      end)

    edges =
      Enum.map(raw_edges, fn e -> %{from: nf(e, "from"), to: nf(e, "to")} end)
      |> Enum.filter(&(&1.from && &1.to))

    # Surface the virtual `start` origin when any edge fans out from the start
    # sentinel, so the trigger origin is visible (and selectable) in the DAG.
    {nodes, edges} = maybe_inject_start_node(nodes, edges)

    if nodes == [] do
      %{nodes: [], pos: %{}, edges: [], width: 200, height: 80}
    else
      levels = assign_dag_levels(nodes, edges)

      by_level =
        nodes
        |> Enum.group_by(&Map.get(levels, &1.name, 0))
        |> Enum.map(fn {level, ns} -> {level, Enum.sort_by(ns, & &1.index)} end)

      _max_level = by_level |> Enum.map(fn {l, _} -> l end) |> Enum.max()

      row_widths =
        Map.new(by_level, fn {level, ns} ->
          n = length(ns)
          {level, n * @dag_node_w + max(0, n - 1) * @dag_h_gap}
        end)

      max_row_w = row_widths |> Map.values() |> Enum.max()
      total_w = max_row_w + 2 * @dag_pad_x

      positioned =
        for {level, level_nodes} <- by_level,
            {node, idx} <- Enum.with_index(level_nodes) do
          row_w = Map.get(row_widths, level)

          x =
            @dag_pad_x + div(total_w - 2 * @dag_pad_x - row_w, 2) +
              idx * (@dag_node_w + @dag_h_gap)

          y = @dag_pad_y + level * (@dag_node_h + @dag_v_gap)
          inner = compute_node_inner(node.params, node.is_batch, node.is_map)

          %{
            name: node.name,
            x: x,
            y: y,
            w: @dag_node_w,
            h: @dag_node_h + inner.h_extra,
            is_hitl: node.is_hitl,
            is_batch: node.is_batch,
            is_map: node.is_map,
            is_start: node.is_start,
            inner: inner,
            separator_y: @dag_node_h
          }
        end

      pos_map = Map.new(positioned, &{&1.name, &1})

      actual_h =
        positioned |> Enum.map(fn n -> n.y + n.h end) |> Enum.max() |> Kernel.+(@dag_pad_y)

      %{nodes: positioned, pos: pos_map, edges: edges, width: total_w, height: actual_h}
    end
  end

  # The reserved sentinel `from` name for the virtual trigger origin. Mirrors
  # `Zaq.Engine.Workflows.DagBuilder`'s start sentinel.
  @start_sentinel "start"

  # When the DAG branches off `from: "start"` edges there is no real node behind
  # them, so neither the origin nor its edges render. Inject a synthetic origin
  # node (index -1 → leveled above its targets) so the trigger is shown and can
  # be selected to reveal the run's input payload.
  defp maybe_inject_start_node(nodes, edges) do
    fans_from_start? = Enum.any?(edges, &(&1.from == @start_sentinel))
    has_start_node? = Enum.any?(nodes, &(&1.name == @start_sentinel))

    if fans_from_start? and not has_start_node? do
      start_node = %{
        name: @start_sentinel,
        type: @start_sentinel,
        index: -1,
        is_hitl: false,
        is_batch: false,
        is_map: false,
        is_start: true,
        params: %{}
      }

      {[start_node | nodes], edges}
    else
      {nodes, edges}
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
  defp nf(nil, _key), do: nil

  defp nf(%{} = m, key) when is_binary(key) do
    Map.get(m, key) || Map.get(m, String.to_existing_atom(key))
  rescue
    _ -> Map.get(m, key)
  end

  # Node colour selection: status colours override type colours so a running batch
  # node shows blue (running), not its default purple.
  # The virtual `start` origin is always styled as a trigger pill (indigo),
  # independent of run status — it has no StepRun of its own.
  defp dag_node_colors(_sr, _is_hitl, _is_batch, _is_map, true),
    do: {"#eef2ff", "#6366f1", "#4338ca"}

  defp dag_node_colors(sr, is_hitl, is_batch, is_map, _is_start) do
    dag_status_colors(nf(sr, "status"), is_hitl) ||
      dag_type_colors(is_batch, is_map)
  end

  defp dag_status_colors("running", _), do: {"#eff6ff", "#3b82f6", "#1d4ed8"}
  defp dag_status_colors("completed", _), do: {"#f0fdf4", "#22c55e", "#15803d"}
  defp dag_status_colors("failed", _), do: {"#fef2f2", "#ef4444", "#dc2626"}
  defp dag_status_colors("waiting", _), do: {"#fffbeb", "#f59e0b", "#92400e"}
  defp dag_status_colors("paused", _), do: {"#f8fafc", "#94a3b8", "#475569"}
  defp dag_status_colors("pending", _), do: {"#f9fafb", "#9ca3af", "#6b7280"}
  defp dag_status_colors(_, true), do: {"#fffbeb", "#f59e0b", "#92400e"}
  defp dag_status_colors(_, _), do: nil

  defp dag_type_colors(true, _), do: {"#faf5ff", "#a855f7", "#7e22ce"}
  defp dag_type_colors(_, true), do: {"#f0f9ff", "#0ea5e9", "#0369a1"}
  defp dag_type_colors(_, _), do: {"#f4f4f5", "#d1d5db", "#374151"}

  defp hitl_module?(nil), do: false
  defp hitl_module?(mod) when is_binary(mod), do: String.contains?(mod, "HumanInTheLoop")
  defp hitl_module?(_), do: false

  # ── DAG inner-pipeline helpers ───────────────────────────────────

  # Returns structured inner content for SVG rendering inside batch/iterate nodes.
  #
  # For batch nodes: %{type: :batch, sub_nodes: [...], pipeline_line: nil, h_extra: N}
  #   sub_nodes: list of %{sub_label, is_iterate, pipeline_line, y_offset, h}
  #
  # For iterate nodes: %{type: :iterate, sub_nodes: [], pipeline_line: "step1 → …", h_extra: N}
  #
  # For all others: %{type: :none, sub_nodes: [], pipeline_line: nil, h_extra: 0}
  #
  # Sub-node heights:
  #   - With pipeline_line:  44px  (22 header + 22 pipeline area)
  #   - Without:             22px  (header only)
  # Gap between sub-nodes: 6px.  Outer padding: 8px top + 8px bottom.

  @empty_inner %{type: :none, sub_nodes: [], mini_nodes: [], h_extra: 0, post_section_y: nil}

  defp compute_node_inner(_params, false, false), do: @empty_inner

  defp compute_node_inner(params, true, _is_map) when is_map(params),
    do: compute_batch_node_inner(params)

  # A `map` node shows its `body` pipeline (and any `post_process` tail) as a
  # vertical full-node stack — it is the iteration primitive.
  defp compute_node_inner(params, _is_batch, true) when is_map(params) do
    body = Map.get(params, "body") || Map.get(params, :body) || []
    post = Map.get(params, "post_process") || Map.get(params, :post_process) || []
    names = Enum.map(body ++ post, &(Map.get(&1, "name") || Map.get(&1, :name) || "?"))
    iterate_inner(names)
  end

  defp compute_node_inner(_params, _is_batch, _is_map), do: @empty_inner

  defp iterate_inner([]), do: @empty_inner

  defp iterate_inner(names) do
    full_nodes = compute_iter_full_nodes(names)

    %{
      type: :iterate,
      sub_nodes: [],
      mini_nodes: full_nodes,
      h_extra: 4 + full_nodes_h(full_nodes),
      post_section_y: nil
    }
  end

  defp compute_batch_node_inner(params) do
    process_steps = Map.get(params, "process") || Map.get(params, :process) || []
    post_steps = Map.get(params, "post_process") || Map.get(params, :post_process) || []

    {proc_nodes, y_acc} = Enum.map_reduce(process_steps, 8, &build_batch_sub_node/2)

    {post_section_y, post_nodes} =
      if post_steps == [] do
        {nil, []}
      else
        sep_y = y_acc + 6
        {pnodes, _} = Enum.map_reduce(post_steps, sep_y + 20, &build_batch_sub_node/2)
        {sep_y, pnodes}
      end

    sub_nodes = proc_nodes ++ post_nodes

    case sub_nodes do
      [] ->
        @empty_inner

      _ ->
        last = List.last(sub_nodes)

        %{
          type: :batch,
          sub_nodes: sub_nodes,
          mini_nodes: [],
          h_extra: last.y_offset + last.h + 8,
          post_section_y: post_section_y
        }
    end
  end

  # Each Batch `process`/`post_process` step renders as one flat sub-node row. The
  # iterated body is the flat `process` pipeline — there is no nested Iterate node to
  # expand (delivery mode is the `delivery` param, surfaced in the step card).
  defp build_batch_sub_node(step, y_off) do
    name = Map.get(step, "name") || Map.get(step, :name) || "?"
    sub_h = 28

    sub_node = %{
      sub_label: "▸ #{dag_trunc(name, 22)}",
      mini_nodes: [],
      y_offset: y_off,
      h: sub_h
    }

    {sub_node, y_off + sub_h + 6}
  end

  # Returns total pixel height of a stacked full-node section (8px top + nodes + gaps + 8px bottom).
  defp full_nodes_h([]), do: 0

  defp full_nodes_h(nodes) do
    n = length(nodes)
    8 + n * @full_node_h + (n - 1) * @full_node_gap + 8
  end

  defp dag_trunc(str, max) when is_binary(str) do
    if String.length(str) <= max, do: str, else: String.slice(str, 0, max - 1) <> "…"
  end

  # Computes full-size vertical node layout for an iterate pipeline.
  # Each step becomes a proper node box stacked top-to-bottom with downward arrows.
  # Returns a list of %{label, y_in_section, has_arrow_below}.
  defp compute_iter_full_nodes([]), do: []

  defp compute_iter_full_nodes(names) do
    n = length(names)

    names
    |> Enum.with_index()
    |> Enum.map(fn {name, i} ->
      %{
        label: name,
        y_in_section: 8 + i * (@full_node_h + @full_node_gap),
        has_arrow_below: i < n - 1
      }
    end)
  end
end
