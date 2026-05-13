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

  def run_duration(assigns) do
    ~H"""
    <span class="font-mono text-[0.75rem] text-black/60">
      {format_duration(@run)}
    </span>
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

  defp status_class("active"), do: "bg-emerald-100 text-emerald-700"
  defp status_class("archived"), do: "bg-black/5 text-black/30"
  defp status_class(_), do: "bg-amber-100 text-amber-700"

  defp run_status_class("completed"), do: "bg-emerald-100 text-emerald-700"
  defp run_status_class("failed"), do: "bg-red-100 text-red-600"
  defp run_status_class("running"), do: "bg-blue-100 text-blue-600"
  defp run_status_class(_), do: "bg-black/5 text-black/40"

  defp log_row_class("error"), do: "text-red-700"
  defp log_row_class("warn"), do: "text-amber-700"
  defp log_row_class(_), do: "text-black"

  defp format_duration(%{started_at: nil}), do: "—"
  defp format_duration(%{started_at: started_at, finished_at: nil}), do: elapsed(started_at)

  defp format_duration(%{started_at: started_at, finished_at: finished_at}) do
    diff = DateTime.diff(finished_at, started_at, :second)
    format_seconds(diff)
  end

  defp elapsed(started_at) do
    diff = DateTime.diff(DateTime.utc_now(), started_at, :second)
    format_seconds(diff) <> "…"
  end

  defp format_seconds(s) when s < 60, do: "#{s}s"
  defp format_seconds(s), do: "#{div(s, 60)}m #{rem(s, 60)}s"
end
