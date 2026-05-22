defmodule ZaqWeb.Live.BO.AI.TriggerComponents do
  @moduledoc """
  Shared function components for the Triggers BO page.
  """
  use Phoenix.Component
  use ZaqWeb, :verified_routes

  import ZaqWeb.Live.BO.AI.WorkflowComponents, only: [run_status_badge: 1]
  import ZaqWeb.Components.SearchableSelect

  # ── Explainer ────────────────────────────────────────────────────

  @doc "Collapsible callout explaining how triggers work."
  attr :open, :boolean, default: false

  def trigger_explainer(assigns) do
    ~H"""
    <details open={@open} class="group mb-6">
      <summary class="cursor-pointer list-none flex items-center gap-2 text-[var(--zaq-color-ink-soft)] hover:text-[var(--zaq-color-ink)] transition-colors">
        <svg
          class="w-4 h-4 text-[var(--zaq-color-accent)] flex-shrink-0 transition-transform group-open:rotate-90"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
        </svg>
        <span class="font-mono text-[0.75rem] font-semibold uppercase tracking-wider">
          How triggers work
        </span>
      </summary>
      <div class="mt-3 ml-6 p-4 rounded-xl bg-[var(--zaq-color-accent-soft)] border border-[var(--zaq-color-surface-border)]">
        <p class="font-mono text-[0.78rem] text-[var(--zaq-color-ink)] leading-relaxed">
          A trigger listens for a named event — like
          <code class="px-1 py-0.5 rounded bg-white/60 text-[var(--zaq-color-accent)]">
            email.received
          </code>
          or
          <code class="px-1 py-0.5 rounded bg-white/60 text-[var(--zaq-color-accent)]">
            webhook.posted
          </code>
          — and automatically starts one or more workflows the moment that event arrives.
          You choose which events to listen to and which workflows to run.
          Triggers can be disabled at any time without losing their configuration.
          When a trigger fires, each connected workflow gets its own independent run,
          carrying the event's payload as its starting data.
        </p>
      </div>
    </details>
    """
  end

  # ── Event badge ──────────────────────────────────────────────────

  @doc "Pill showing the trigger's event_name with a bolt icon."
  attr :event_name, :string, required: true
  attr :enabled, :boolean, default: true

  def event_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 font-mono text-[0.72rem] px-2 py-0.5 rounded-full border",
      if(@enabled,
        do:
          "bg-[var(--zaq-color-accent-soft)] border-[var(--zaq-color-accent)]/30 text-[var(--zaq-color-accent)]",
        else: "bg-black/5 border-black/10 text-black/30"
      )
    ]}>
      <svg class="w-3 h-3 flex-shrink-0" fill="currentColor" viewBox="0 0 24 24">
        <path d="M13 2L3 14h9l-1 8 10-12h-9l1-8z" />
      </svg>
      {@event_name}
      <span :if={!@enabled} class="text-[0.65rem]">(disabled)</span>
    </span>
    """
  end

  # ── Workflow chip ─────────────────────────────────────────────────

  @doc "Chip linking to a workflow's detail page."
  attr :workflow, :map, required: true

  def workflow_chip(assigns) do
    ~H"""
    <a
      href={~p"/bo/workflows/#{@workflow.id}"}
      class="inline-flex items-center gap-1.5 font-mono text-[0.72rem] px-2 py-0.5 rounded-lg border border-black/10 bg-white hover:bg-black/[0.03] text-[var(--zaq-color-ink)] transition-colors"
    >
      <span class={[
        "w-1.5 h-1.5 rounded-full flex-shrink-0",
        status_dot_class(@workflow.status)
      ]} />
      {@workflow.name}
      <svg
        class="w-3 h-3 text-black/30"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M10 6H6a2 2 0 00-2 2v10a2 2 0 002 2h10a2 2 0 002-2v-4M14 4h6m0 0v6m0-6L10 14"
        />
      </svg>
    </a>
    """
  end

  # ── Run row ───────────────────────────────────────────────────────

  @doc "One-line run summary with status badge, time, and link to run detail."
  attr :run, :map, required: true
  attr :workflow_id, :string, required: true

  def run_row(assigns) do
    ~H"""
    <a
      href={~p"/bo/workflows/#{@workflow_id}/runs/#{@run.id}"}
      class="flex items-center gap-3 px-3 py-1.5 rounded-lg hover:bg-black/[0.03] transition-colors group"
    >
      <.run_status_badge status={@run.status} />
      <span class="font-mono text-[0.72rem] text-black/40 flex-1">
        {relative_time(@run.inserted_at)}
      </span>
      <svg
        class="w-3.5 h-3.5 text-black/20 group-hover:text-[var(--zaq-color-accent)] transition-colors"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        viewBox="0 0 24 24"
      >
        <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
      </svg>
    </a>
    """
  end

  # ── Trigger card ─────────────────────────────────────────────────

  @doc """
  Full trigger card: event badge, enabled toggle, edit/delete buttons,
  connected workflows, and recent runs.
  """
  attr :trigger, :map, required: true
  attr :enriched_workflows, :list, required: true

  def trigger_card(assigns) do
    ~H"""
    <div class="bg-white rounded-xl border border-black/10 p-5 space-y-4">
      <%!-- Header row --%>
      <div class="flex items-start justify-between gap-3">
        <div class="flex items-center gap-2 flex-wrap">
          <.event_badge event_name={@trigger.event_name} enabled={@trigger.enabled} />
        </div>
        <div class="flex items-center gap-1.5 flex-shrink-0">
          <button
            phx-click="toggle_enabled"
            phx-value-trigger_id={@trigger.id}
            class={[
              "font-mono text-[0.68rem] px-2 py-0.5 rounded border transition-colors",
              if(@trigger.enabled,
                do: "bg-emerald-50 border-emerald-200 text-emerald-700 hover:bg-emerald-100",
                else: "bg-black/5 border-black/10 text-black/40 hover:bg-black/10"
              )
            ]}
          >
            {if @trigger.enabled, do: "Enabled", else: "Disabled"}
          </button>
          <button
            phx-click="open_edit"
            phx-value-trigger_id={@trigger.id}
            class="font-mono text-[0.72rem] px-2 py-1 rounded-lg border border-black/10 text-black/50 hover:text-[var(--zaq-color-ink)] hover:border-black/20 transition-colors"
          >
            Edit
          </button>
          <button
            phx-click="open_delete"
            phx-value-trigger_id={@trigger.id}
            class="font-mono text-[0.72rem] px-2 py-1 rounded-lg border border-red-100 text-red-400 hover:bg-red-50 transition-colors"
          >
            Delete
          </button>
        </div>
      </div>

      <%!-- Workflows --%>
      <div>
        <p class="font-mono text-[0.65rem] uppercase tracking-wider text-black/30 mb-2">
          Connected workflows
        </p>
        <div class="flex flex-wrap gap-2 items-center">
          <div :for={%{workflow: w} <- @enriched_workflows} class="inline-flex items-center gap-1">
            <.workflow_chip workflow={w} />
            <button
              phx-click="remove_workflow"
              phx-value-trigger_id={@trigger.id}
              phx-value-workflow_id={w.id}
              class="inline-flex items-center justify-center w-4 h-4 rounded-full text-black/30 hover:text-red-400 hover:bg-red-50 transition-colors"
              aria-label="Remove workflow"
            >
              <svg
                class="w-3 h-3"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
          <span :if={@enriched_workflows == []} class="font-mono text-[0.72rem] text-black/30">
            None yet
          </span>
          <button
            phx-click="open_assign"
            phx-value-trigger_id={@trigger.id}
            class="inline-flex items-center gap-1 font-mono text-[0.72rem] px-2 py-0.5 rounded-lg border border-dashed border-black/20 text-black/40 hover:text-[var(--zaq-color-accent)] hover:border-[var(--zaq-color-accent)] transition-colors"
          >
            <svg
              class="w-3 h-3"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M12 5v14M5 12h14" />
            </svg>
            Connect
          </button>
        </div>
      </div>

      <%!-- Last run --%>
      <% last = latest_run(@enriched_workflows) %>
      <div :if={last != nil}>
        <p class="font-mono text-[0.65rem] uppercase tracking-wider text-black/30 mb-1">
          Last run
        </p>
        <.run_row run={elem(last, 1)} workflow_id={elem(last, 0).id} />
      </div>
    </div>
    """
  end

  # ── Trigger form ─────────────────────────────────────────────────

  @doc "Form used in both create and edit modals."
  attr :form, :map, required: true
  attr :known_events, :list, default: []

  def trigger_form(assigns) do
    ~H"""
    <div class="space-y-4">
      <div>
        <label class="block font-mono text-[0.72rem] text-black/50 mb-1">Event name</label>
        <.searchable_select
          id="trigger-event-name-select"
          name="trigger[event_name]"
          value={Phoenix.HTML.Form.input_value(@form, :event_name)}
          options={Enum.map(@known_events, &{&1, &1})}
          placeholder="Search events..."
          empty_label="Select or type an event..."
          allow_create={true}
          on_create_event="set_event_name"
        />
        <p
          :if={@form[:event_name].errors != []}
          class="font-mono text-[0.68rem] text-red-500 mt-1"
        >
          {translate_error(hd(@form[:event_name].errors))}
        </p>
      </div>
      <div class="flex items-center gap-3">
        <input
          type="checkbox"
          name="trigger[enabled]"
          id="trigger_enabled"
          checked={Phoenix.HTML.Form.input_value(@form, :enabled)}
          class="w-4 h-4 rounded border-black/20 accent-[var(--zaq-color-accent)]"
        />
        <label for="trigger_enabled" class="font-mono text-[0.78rem] text-[var(--zaq-color-ink)]">
          Enabled
        </label>
      </div>
    </div>
    """
  end

  # ── Helpers ───────────────────────────────────────────────────────

  defp latest_run(enriched_workflows) do
    enriched_workflows
    |> Enum.flat_map(fn %{workflow: w, recent_runs: runs} -> Enum.map(runs, &{w, &1}) end)
    |> Enum.max_by(fn {_, run} -> run.inserted_at end, DateTime, fn -> nil end)
  end

  defp status_dot_class("active"), do: "bg-emerald-400"
  defp status_dot_class("draft"), do: "bg-amber-400"
  defp status_dot_class(_), do: "bg-black/20"

  defp relative_time(nil), do: "—"

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 60 -> "just now"
      diff < 3600 -> "#{div(diff, 60)} min ago"
      diff < 86_400 -> "#{div(diff, 3600)} hr ago"
      true -> "#{div(diff, 86_400)} days ago"
    end
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
