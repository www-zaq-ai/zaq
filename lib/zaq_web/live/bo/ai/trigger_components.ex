defmodule ZaqWeb.Live.BO.AI.TriggerComponents do
  @moduledoc """
  Shared function components for the Triggers BO page.
  """
  use Phoenix.Component
  use ZaqWeb, :verified_routes

  import ZaqWeb.Live.BO.AI.WorkflowComponents, only: [run_status_badge: 1]
  import ZaqWeb.Components.SearchableSelect

  alias Phoenix.HTML.Form, as: HTMLForm

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
      {display_event_name(@event_name)}
    </span>
    """
  end

  # ── Workflow row ──────────────────────────────────────────────────

  @doc """
  Full-width connected-workflow row: status dot, workflow name link, the
  latest run's status badge and relative time, plus remove and open controls.
  """
  attr :trigger_id, :string, required: true
  attr :workflow, :map, required: true
  attr :run, :map, default: nil

  def workflow_row(assigns) do
    ~H"""
    <div class="group flex items-center gap-3 px-3 py-2.5 rounded-lg border border-black/[0.06] bg-black/[0.015] hover:bg-black/[0.03] transition-colors">
      <span class={[
        "w-1.5 h-1.5 rounded-full flex-shrink-0",
        status_dot_class(@workflow.status)
      ]} />
      <a
        href={~p"/bo/workflows/#{@workflow.id}"}
        class="inline-flex items-center gap-1 font-mono text-[0.78rem] font-semibold text-[var(--zaq-color-ink)] hover:text-[var(--zaq-color-accent)] transition-colors"
      >
        {@workflow.name}
        <svg
          class="w-3 h-3 text-black/30 flex-shrink-0"
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

      <div :if={@run} class="flex items-center gap-2.5 min-w-0">
        <svg
          class="w-3.5 h-3.5 text-black/20 flex-shrink-0"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M5 12h14M13 6l6 6-6 6" />
        </svg>
        <.run_status_badge status={@run.status} />
        <span class="font-mono text-[0.72rem] text-black/40 whitespace-nowrap">
          {relative_time(@run.inserted_at)}
        </span>
      </div>
      <span :if={is_nil(@run)} class="font-mono text-[0.72rem] text-black/30">no runs yet</span>

      <div class="ml-auto flex items-center gap-1 flex-shrink-0">
        <button
          phx-click="remove_workflow"
          phx-value-trigger_id={@trigger_id}
          phx-value-workflow_id={@workflow.id}
          class="inline-flex items-center justify-center w-6 h-6 rounded-md text-black/25 hover:text-red-400 hover:bg-red-50 transition-colors"
          aria-label="Remove workflow"
        >
          <svg
            class="w-3.5 h-3.5"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
          </svg>
        </button>
        <a
          href={open_href(@workflow, @run)}
          class="inline-flex items-center justify-center w-6 h-6 rounded-md text-black/25 group-hover:text-black/45 hover:!text-[var(--zaq-color-accent)] transition-colors"
          aria-label={if @run, do: "Open latest run", else: "Open workflow"}
        >
          <svg
            class="w-3.5 h-3.5"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
          </svg>
        </a>
      </div>
    </div>
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
    <div class="bg-white rounded-xl border border-black/10 p-5">
      <%!-- Header row --%>
      <div class="flex items-center justify-between gap-3 mb-4">
        <.event_badge event_name={@trigger.event_name} enabled={@trigger.enabled} />

        <div class="flex items-center gap-2 flex-shrink-0">
          <button
            phx-click="toggle_enabled"
            phx-value-trigger_id={@trigger.id}
            type="button"
            role="switch"
            aria-checked={to_string(@trigger.enabled)}
            aria-label={if @trigger.enabled, do: "Disable trigger", else: "Enable trigger"}
            class={[
              "relative inline-flex items-center h-5 w-9 rounded-full transition-colors flex-shrink-0",
              if(@trigger.enabled, do: "bg-[var(--zaq-color-accent)]", else: "bg-black/15")
            ]}
          >
            <span class={[
              "inline-block h-4 w-4 rounded-full bg-white shadow transform transition-transform",
              if(@trigger.enabled, do: "translate-x-4", else: "translate-x-0.5")
            ]} />
          </button>
          <span class={[
            "font-mono text-[0.72rem] font-semibold mr-1",
            if(@trigger.enabled, do: "text-[var(--zaq-color-ink)]", else: "text-black/40")
          ]}>
            {if @trigger.enabled, do: "Enabled", else: "Disabled"}
          </span>
          <button
            phx-click="open_edit"
            phx-value-trigger_id={@trigger.id}
            class="font-mono text-[0.72rem] px-2.5 py-1 rounded-lg border border-black/10 text-black/60 hover:text-[var(--zaq-color-ink)] hover:border-black/20 transition-colors"
          >
            Edit
          </button>
          <button
            phx-click="open_delete"
            phx-value-trigger_id={@trigger.id}
            class="font-mono text-[0.72rem] px-2.5 py-1 rounded-lg border border-red-100 text-red-500 hover:bg-red-50 transition-colors"
          >
            Delete
          </button>
        </div>
      </div>

      <%!-- Connected workflows --%>
      <p class="font-mono text-[0.65rem] uppercase tracking-wider text-black/30 mb-2">
        Connected workflows
      </p>
      <div class="space-y-2">
        <.workflow_row
          :for={%{workflow: w, recent_runs: runs} <- @enriched_workflows}
          trigger_id={@trigger.id}
          workflow={w}
          run={latest_run_for(runs)}
        />
        <button
          phx-click="open_assign"
          phx-value-trigger_id={@trigger.id}
          class="inline-flex items-center gap-1.5 font-mono text-[0.72rem] font-semibold px-3 py-2 rounded-lg border border-dashed border-black/20 text-black/50 hover:text-[var(--zaq-color-accent)] hover:border-[var(--zaq-color-accent)] transition-colors"
        >
          <svg
            class="w-3.5 h-3.5"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M12 5v14M5 12h14" />
          </svg>
          Connect workflow
        </button>
      </div>
    </div>
    """
  end

  # ── Trigger form ─────────────────────────────────────────────────

  @cron_presets [
    {"Every 5 min", "*/5 * * * *"},
    {"Every 15 min", "*/15 * * * *"},
    {"Every 30 min", "*/30 * * * *"},
    {"Hourly", "0 * * * *"},
    {"Daily", "0 0 * * *"},
    {"Weekly (Mon)", "0 0 * * 1"},
    {"Custom", :custom}
  ]

  @doc "Form used in both create and edit modals."
  attr :form, :map, required: true
  attr :known_events, :list, default: []
  attr :temporary_events, :list, default: []

  def trigger_form(assigns) do
    trigger_type = HTMLForm.input_value(assigns.form, :trigger_type) || "event"
    cron_schedule = HTMLForm.input_value(assigns.form, :cron_schedule)

    preset_value =
      case Enum.find(@cron_presets, fn {_, expr} -> expr == cron_schedule end) do
        nil -> if cron_schedule in [nil, ""], do: "*/5 * * * *", else: :custom
        {_, expr} -> expr
      end

    assigns =
      assigns
      |> assign(:trigger_type, to_string(trigger_type))
      |> assign(:cron_preset, preset_value)
      |> assign(:cron_schedule, cron_schedule || "")
      |> assign(:cron_presets, @cron_presets)

    ~H"""
    <div class="space-y-4">
      <%!-- Trigger type selector --%>
      <div>
        <label class="block font-mono text-[0.72rem] text-black/50 mb-2">Trigger type</label>
        <div class="flex gap-3">
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="radio"
              name="trigger[trigger_type]"
              value="event"
              checked={@trigger_type == "event"}
              class="accent-[var(--zaq-color-accent)]"
            />
            <span class="font-mono text-[0.78rem] text-[var(--zaq-color-ink)]">Event</span>
          </label>
          <label class="flex items-center gap-2 cursor-pointer">
            <input
              type="radio"
              name="trigger[trigger_type]"
              value="cron"
              checked={@trigger_type == "cron"}
              class="accent-[var(--zaq-color-accent)]"
            />
            <span class="font-mono text-[0.78rem] text-[var(--zaq-color-ink)]">Cron schedule</span>
          </label>
        </div>
      </div>

      <%!-- Event name (shown for event type) --%>
      <div :if={@trigger_type != "cron"}>
        <label class="block font-mono text-[0.72rem] text-black/50 mb-1">Event name</label>
        <.searchable_select
          id="trigger-event-name-select"
          name="trigger[event_name]"
          value={display_event_name(HTMLForm.input_value(@form, :event_name))}
          options={event_options(@known_events, @temporary_events)}
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

      <%!-- Cron schedule (shown for cron type) --%>
      <div :if={@trigger_type == "cron"} class="space-y-3">
        <div>
          <label class="block font-mono text-[0.72rem] text-black/50 mb-1">Event name</label>
          <input
            type="text"
            name="trigger[event_name]"
            value={display_event_name(HTMLForm.input_value(@form, :event_name))}
            placeholder="e.g. cron.daily_report"
            class="w-full font-mono text-[0.82rem] text-[var(--zaq-color-ink)] px-3 py-1.5 rounded-lg border border-black/15 focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent)]/30"
          />
          <p class="font-mono text-[0.65rem] text-black/35 mt-1">
            The event fired each time the schedule triggers (used to link workflows).
          </p>
          <p
            :if={@form[:event_name].errors != []}
            class="font-mono text-[0.68rem] text-red-500 mt-1"
          >
            {translate_error(hd(@form[:event_name].errors))}
          </p>
        </div>

        <div>
          <label class="block font-mono text-[0.72rem] text-black/50 mb-1">Schedule</label>
          <select
            name="trigger[cron_preset]"
            id="trigger_cron_preset"
            class="w-full font-mono text-[0.82rem] text-[var(--zaq-color-ink)] px-3 py-1.5 rounded-lg border border-black/15 focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent)]/30"
          >
            <option
              :for={{label, expr} <- @cron_presets}
              value={if expr == :custom, do: "custom", else: expr}
              selected={
                if expr == :custom,
                  do: @cron_preset == :custom,
                  else: @cron_preset == expr
              }
            >
              {label}
            </option>
          </select>
        </div>

        <%!-- Hidden or visible cron expression input --%>
        <div :if={@cron_preset == :custom}>
          <label class="block font-mono text-[0.72rem] text-black/50 mb-1">
            Custom cron expression
          </label>
          <input
            type="text"
            name="trigger[cron_schedule]"
            value={@cron_schedule}
            placeholder="e.g. 0 9 * * 1-5"
            class="w-full font-mono text-[0.82rem] text-[var(--zaq-color-ink)] px-3 py-1.5 rounded-lg border border-black/15 focus:outline-none focus:ring-2 focus:ring-[var(--zaq-color-accent)]/30"
          />
          <p class="font-mono text-[0.65rem] text-black/35 mt-1">
            5-field cron: minute hour day month weekday
          </p>
        </div>

        <%!-- Hidden input carrying the preset expression when not custom --%>
        <input
          :if={@cron_preset != :custom}
          type="hidden"
          name="trigger[cron_schedule]"
          value={@cron_preset}
        />

        <p
          :if={@form[:cron_schedule].errors != []}
          class="font-mono text-[0.68rem] text-red-500"
        >
          {translate_error(hd(@form[:cron_schedule].errors))}
        </p>
      </div>

      <div class="flex items-center gap-3">
        <%!-- Hidden fallback so unchecked state sends false instead of omitting the field --%>
        <input type="hidden" name="trigger[enabled]" value="false" />
        <input
          type="checkbox"
          name="trigger[enabled]"
          id="trigger_enabled"
          value="true"
          checked={HTMLForm.input_value(@form, :enabled)}
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

  defp latest_run_for(runs) when is_list(runs) and runs != [],
    do: Enum.max_by(runs, & &1.inserted_at, DateTime, fn -> nil end)

  defp latest_run_for(_), do: nil

  # The open (›) control drills into the latest run when one exists, otherwise
  # falls back to the workflow's detail page.
  defp open_href(workflow, nil), do: ~p"/bo/workflows/#{workflow.id}"
  defp open_href(workflow, run), do: ~p"/bo/workflows/#{workflow.id}/runs/#{run.id}"

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

  # Strips the internal "engine:" routing prefix before showing to users.
  # e.g. "engine:cron.daily_sync" → "cron.daily_sync"
  defp display_event_name(nil), do: ""
  defp display_event_name(name), do: String.replace_prefix(name, "engine:", "")

  defp event_options(known_events, temporary_events) do
    temporary_events = Enum.map(temporary_events, &display_event_name/1)

    known_events
    |> Enum.map(&display_event_name/1)
    |> Kernel.++(temporary_events)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(fn event_name ->
      if event_name in temporary_events do
        {event_name, event_name, "- not saved yet"}
      else
        {event_name, event_name}
      end
    end)
  end

  defp translate_error({msg, opts}) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", to_string(value))
    end)
  end
end
