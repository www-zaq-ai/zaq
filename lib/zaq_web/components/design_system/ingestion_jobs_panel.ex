defmodule ZaqWeb.Components.DesignSystem.IngestionJobsPanel do
  @moduledoc """
  BO ingestion jobs list with status filter chips.
  """

  use Phoenix.Component

  import ZaqWeb.Helpers.DateFormat

  alias ZaqWeb.Components.DesignSystem.StatusPill

  attr :jobs, :list, required: true
  attr :status_filter, :string, required: true

  def jobs_panel(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-3">
        <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider">Jobs</p>
        <p class="font-mono text-[0.68rem] text-black/30">{length(@jobs)}</p>
      </div>

      <div class="flex gap-1 mb-3 flex-wrap">
        <button
          :for={
            {status, label} <- [
              {"all", "all"},
              {"completed", "completed"},
              {"failed", "failed"},
              {"others", "others"}
            ]
          }
          phx-click="filter_status"
          phx-value-status={status}
          class={[
            "font-mono text-[0.68rem] px-2 py-1 rounded-lg transition-colors whitespace-nowrap cursor-pointer",
            if(@status_filter == status,
              do: "bg-[var(--zaq-color-accent)] text-white",
              else: "bg-black/5 text-black/40 hover:bg-black/10"
            )
          ]}
        >
          {label}
        </button>
      </div>

      <div class="space-y-2 max-h-[80vh] overflow-y-auto">
        <div
          :if={@jobs == []}
          class="bg-white rounded-xl border border-dashed border-black/10 p-6 text-center"
        >
          <p class="font-mono text-[0.8rem] text-black/30">No jobs yet</p>
        </div>

        <div
          :for={job <- @jobs}
          class="bg-white rounded-xl border border-black/[0.06] shadow-sm p-4 space-y-2"
        >
          <div class="flex items-start justify-between gap-2">
            <p class="font-mono text-[0.82rem] text-black font-medium truncate" title={job.file_path}>
              {Path.basename(job.file_path)}
            </p>
            <span class={[
              "shrink-0 font-mono text-[0.65rem] px-2 py-0.5 rounded",
              StatusPill.status_color(job.status)
            ]}>
              {job.status}
            </span>
          </div>

          <div class="font-mono text-[0.68rem] text-black/60 space-y-0.5">
            <p>Mode: {job.mode}</p>
            <p>Started: {format_datetime(job.started_at)}</p>
            <p :if={job.completed_at}>Completed: {format_datetime(job.completed_at)}</p>
            <p :if={job.total_chunks > 0}>Chunks: {job.ingested_chunks}/{job.total_chunks}</p>
            <progress
              :if={job.total_chunks > 0}
              class="h-1.5 w-full overflow-hidden rounded-full [&::-webkit-progress-bar]:bg-zinc-200 [&::-webkit-progress-value]:bg-emerald-500"
              value={job.ingested_chunks}
              max={job.total_chunks}
            >
              {job.ingested_chunks}/{job.total_chunks}
            </progress>
            <p :if={job.failed_chunks > 0}>Failed chunks: {job.failed_chunks}</p>
            <p :if={job.total_chunks == 0 and job.chunks_count > 0}>Chunks: {job.chunks_count}</p>
            <details :if={job.error} class="mt-1">
              <summary class="font-mono text-[0.7rem] text-red-500 cursor-pointer hover:text-red-600">
                Error details
              </summary>
              <pre class="mt-1 text-[0.65rem] text-red-400 whitespace-pre-wrap break-all">{job.error}</pre>
              <a
                :if={String.starts_with?(job.error, "Embedding dimension mismatch")}
                href="/bo/system-config?tab=embedding"
                class="mt-1 inline-block text-[0.65rem] text-blue-400 hover:underline"
              >
                Go to Embedding settings →
              </a>
            </details>
          </div>

          <div class="flex gap-1.5 pt-1">
            <button
              :if={job.status in ~w(failed completed_with_errors)}
              phx-click="retry_job"
              phx-value-id={job.id}
              class="font-mono text-[0.65rem] px-2 py-1 rounded-lg bg-black/5 text-black/50 hover:bg-black/10 transition-colors"
            >
              Retry
            </button>
            <button
              :if={job.status in ~w(pending processing)}
              phx-click="cancel_job"
              phx-value-id={job.id}
              class="font-mono text-[0.65rem] px-2 py-1 rounded-lg bg-red-500/10 text-red-500 hover:bg-red-500/20 transition-colors"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
