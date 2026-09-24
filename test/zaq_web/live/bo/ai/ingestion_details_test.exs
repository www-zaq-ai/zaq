defmodule ZaqWeb.Live.BO.AI.IngestionDetailsTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.IngestionDetails
  alias ZaqWeb.Helpers.Markdown

  test "renders the default-analyzer recap and the shared extracted Markdown preview" do
    details = %{
      filename: "rapport.pdf",
      summary: %{
        "index_backend" => "parade_db",
        "total_chunks_detected" => 2,
        "total_chunks_indexed" => 2,
        "total_chunks_simple_indexed" => 2,
        "detected_languages" => ["french"],
        "errors" => []
      },
      preview: %{
        kind: :markdown,
        filename: "rapport.pdf",
        ext: ".md",
        rendered_html: Markdown.render("# Contenu extrait\n\nBonjour")
      }
    }

    html = render_component(&IngestionDetails.modal/1, details: details)

    assert html =~ "Ingestion details · rapport.pdf"
    assert html =~ "French"
    assert html =~ "2 default analyzer"
    assert html =~ "0 language-specific"
    assert html =~ "Contenu extrait"
    assert html =~ "zaq-file-preview-body md-content"
    assert html =~ ~s(phx-click="close_ingestion_details")
  end
end
