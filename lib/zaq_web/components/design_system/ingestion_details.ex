defmodule ZaqWeb.Components.DesignSystem.IngestionDetails do
  @moduledoc """
  BO modal for persisted chunk indexing progress and extracted Markdown.

  The parent fetches the authorized document on demand; this component only
  renders the summary and preview using the shared preview panel.
  """

  use Phoenix.Component

  alias ZaqWeb.Components.{BOModal, FilePreview}
  alias ZaqWeb.Components.DesignSystem.IngestionProgress

  attr :details, :map, required: true

  def modal(assigns) do
    ~H"""
    <BOModal.modal_shell
      id="ingestion-details-modal"
      cancel_event="close_ingestion_details"
      title={"Ingestion details · #{@details.filename}"}
      max_width_class="zaq-modal--width-6xl"
    >
      <div class="zaq-ingestion-details-content">
        <section aria-label="Chunk indexing progress">
          <IngestionProgress.ingestion_progress summary={@details.summary} />
        </section>
        <section aria-label="Extracted Markdown">
          <h4 class="zaq-text-h4 mb-2">Extracted Markdown</h4>
          <div class="zaq-file-preview-scroll">
            <FilePreview.panel preview={@details.preview} />
          </div>
        </section>
      </div>
    </BOModal.modal_shell>
    """
  end
end
