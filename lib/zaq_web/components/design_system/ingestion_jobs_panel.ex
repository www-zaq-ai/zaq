defmodule ZaqWeb.Components.DesignSystem.IngestionJobsPanel do
  @moduledoc """
  BO ingestion jobs list with status filter toggle.

  Toolbar actions use `.zaq-btn` + `.zaq-btn-tertiary*` (`btn.css`) and `.zaq-btn-text_label-default` (`text-styles.css`) on buttons; non-button copy uses `.zaq-text-caption` where applicable.
  """

  use Phoenix.Component

  import ZaqWeb.Helpers.DateFormat

  alias ZaqWeb.Components.DesignSystem.StatusPill
  alias ZaqWeb.Components.DesignSystem.Toggle

  attr :jobs, :list, required: true
  attr :status_filter, :string, required: true
  attr :prep_progress, :map, default: %{}

  def jobs_panel(assigns) do
    ~H"""
    <div>
      <div class="flex items-center justify-between mb-3">
        <p class="zaq-text-caption zaq-ingestion-meta-label">Jobs</p>
        <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
          {length(@jobs)}
        </p>
      </div>

      <Toggle.toggle
        value={@status_filter}
        event="filter_status"
        value_param="status"
        class="mb-3"
        choices={[
          %{value: "all", label: "All", icon: "hero-queue-list", title: "All jobs"},
          %{value: "completed", label: "Completed", icon: "hero-check-circle", title: "Completed"},
          %{value: "failed", label: "Failed", icon: "hero-x-circle", title: "Failed"},
          %{value: "others", label: "Others", icon: "hero-clock", title: "Pending and in progress"}
        ]}
      />

      <div class="space-y-2 max-h-[80vh] overflow-y-auto">
        <div
          :if={@jobs == []}
          class="zaq-card-default zaq-border-default text-center"
          style="background: var(--zaq-surface-color-raised)"
        >
          <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-tertiary)">
            No jobs yet
          </p>
        </div>

        <div
          :for={job <- @jobs}
          class="zaq-card-default zaq-border-default flex flex-col gap-2 shadow-sm"
          style="background: var(--zaq-surface-color-raised)"
        >
          <div class="flex items-start justify-between gap-2">
            <p class="zaq-text-body-sm font-medium truncate" title={job.file_path}>
              {job_display_name(job)}
            </p>
            <span class={StatusPill.status_pill_classes(job.status)}>
              {job.status}
            </span>
          </div>

          <div
            class="zaq-text-body-sm space-y-0.5"
            style="color: var(--zaq-text-color-body-secondary)"
          >
            <p>Mode: {job.mode}</p>
            <p>Started: {format_datetime(job.started_at)}</p>
            <p :if={job.completed_at}>Completed: {format_datetime(job.completed_at)}</p>
            <p :if={job.total_chunks > 0}>Chunks: {job.ingested_chunks}/{job.total_chunks}</p>
            <progress
              :if={job.total_chunks > 0}
              class="zaq-jobs-panel-progress h-1.5 w-full overflow-hidden rounded-full"
              value={job.ingested_chunks}
              max={job.total_chunks}
            >
              {job.ingested_chunks}/{job.total_chunks}
            </progress>
            <p :if={job.failed_chunks > 0}>Failed chunks: {job.failed_chunks}</p>
            <p :if={job.total_chunks == 0 and job.chunks_count > 0}>Chunks: {job.chunks_count}</p>
            <.prep_indicator
              active={job.status == "processing" and job.total_chunks == 0}
              progress={Map.get(@prep_progress, job.id)}
            />
            <details :if={job.error} class="mt-1">
              <summary
                class="zaq-text-caption cursor-pointer transition-opacity hover:opacity-80"
                style="color: var(--zaq-text-color-body-danger)"
              >
                Error details
              </summary>
              <pre
                class="zaq-text-caption mt-1 whitespace-pre-wrap break-all"
                style="color: var(--zaq-text-color-body-danger); opacity: 0.88"
              >{job.error}</pre>
              <a
                :if={String.starts_with?(job.error, "Embedding dimension mismatch")}
                href="/bo/system-config?tab=embedding"
                class="zaq-link-underline zaq-text-caption mt-1 inline-block"
                style="color: var(--zaq-text-color-body-accent)"
              >
                Go to Embedding settings →
              </a>
            </details>
          </div>

          <div class="flex gap-1.5 pt-1">
            <button
              :if={job.status in ~w(failed completed_with_errors)}
              type="button"
              phx-click="retry_job"
              phx-value-id={job.id}
              class="zaq-btn zaq-btn-tertiary zaq-btn-text_label-default"
            >
              Retry
            </button>
            <button
              :if={job.status in ~w(pending processing)}
              type="button"
              phx-click="cancel_job"
              phx-value-id={job.id}
              class="zaq-btn zaq-btn-tertiary zaq-btn-danger zaq-btn-text_label-default"
            >
              Cancel
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # Transient "Preparing…" indicator shown while a PDF is being converted and
  # images are described, before any chunks exist. `progress` is the decoded
  # `ZAQ_PROGRESS` payload (string keys) or nil when none has arrived yet.
  attr :active, :boolean, default: false
  attr :progress, :map, default: nil

  defp prep_indicator(assigns) do
    ~H"""
    <div
      :if={@active}
      class="zaq-text-body-sm space-y-0.5"
      style="color: var(--zaq-text-color-body-secondary)"
    >
      <%= if is_map(@progress) do %>
        <p>Preparing — {prep_text(@progress)}</p>
        <progress
          class="zaq-jobs-panel-progress h-1.5 w-full overflow-hidden rounded-full"
          value={prep_value(@progress)}
          max={prep_total(@progress)}
        >
          {prep_value(@progress)}/{prep_total(@progress)}
        </progress>
      <% else %>
        <p>Preparing — starting…</p>
        <progress class="zaq-jobs-panel-progress h-1.5 w-full overflow-hidden rounded-full" />
      <% end %>
    </div>
    """
  end

  defp prep_text(%{"status" => "started"}), do: "analysing document…"

  # Image-to-text stage carries per-image counts; match the stage explicitly so
  # a future step emitting current/total doesn't get mislabelled as image work.
  defp prep_text(%{"stage" => "image_to_text", "label" => label, "current" => c, "total" => t})
       when is_binary(label),
       do: "describing images #{c}/#{t} — #{label}"

  defp prep_text(%{"stage" => "image_to_text", "current" => c, "total" => t}),
    do: "describing images #{c}/#{t}"

  # Generic fallback for any other Python step reporting current/total progress.
  defp prep_text(%{"current" => c, "total" => t}), do: "processing #{c}/#{t}"
  defp prep_text(_), do: "preparing…"

  # Resolved progress value, clamped to [0, total] so a buggy script emitting
  # `current > total` never renders an overflowed bar.
  defp prep_value(progress), do: min(prep_current(progress), prep_total(progress))

  defp prep_current(%{"current" => c}) when is_integer(c) and c >= 0, do: c
  defp prep_current(_), do: 0

  defp prep_total(%{"total" => t}) when is_integer(t) and t > 0, do: t
  defp prep_total(_), do: 1

  defp job_display_name(%{source_record: %{"name" => name}}) when is_binary(name) and name != "",
    do: name

  defp job_display_name(%{file_path: path}) when is_binary(path), do: Path.basename(path)
  defp job_display_name(_job), do: "Unknown file"
end
