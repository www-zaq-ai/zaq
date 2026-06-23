defmodule Storybook.Ingestion.IngestionJobsPanel do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionJobsPanel

  def description, do: "Ingestion jobs list with status filter chips."

  def render(assigns) do
    jobs = [
      %{
        id: "1",
        file_path: "vol/docs/notes.md",
        status: "completed",
        mode: "async",
        started_at: ~U[2024-06-01 10:00:00Z],
        completed_at: ~U[2024-06-01 10:02:00Z],
        total_chunks: 4,
        ingested_chunks: 4,
        failed_chunks: 0,
        chunks_count: 0,
        error: nil
      },
      %{
        id: "2",
        file_path: "vol/docs/broken.pdf",
        status: "failed",
        mode: "async",
        started_at: ~U[2024-06-02 08:00:00Z],
        completed_at: nil,
        total_chunks: 0,
        ingested_chunks: 0,
        failed_chunks: 0,
        chunks_count: 2,
        error: "sample error"
      }
    ]

    assigns = assign(assigns, :jobs, jobs)

    ~H"""
    <div style="padding: var(--zaq-scale-32); max-width: 24rem;">
      <.jobs_panel jobs={@jobs} status_filter="all" />
    </div>
    """
  end
end
