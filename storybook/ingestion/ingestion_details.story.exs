defmodule Storybook.Ingestion.IngestionDetails do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.IngestionDetails
  alias ZaqWeb.Helpers.Markdown

  def description,
    do: "Ingested badge details: ParadeDB default analyzer, detected languages and extracted Markdown."

  def render(assigns) do
    assigns =
      assign(assigns, :details, %{
        filename: "instructions.pdf",
        summary: %{
          "index_backend" => "parade_db",
          "total_chunks_detected" => 4,
          "total_chunks_indexed" => 3,
          "total_chunks_simple_indexed" => 3,
          "detected_languages" => ["french", "english"],
          "errors" => [%{"chunk_index" => 4, "message" => "Embedding unavailable"}]
        },
        preview: %{
          filename: "instructions.pdf",
          kind: :markdown,
          ext: ".md",
          rendered_html: Markdown.render("# Instructions extraites\n\nTexte français extrait du PDF.")
        }
      })

    ~H"""
    <IngestionDetails.modal details={@details} />
    """
  end
end
