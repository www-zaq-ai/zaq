defmodule ZaqWeb.Live.BO.AI.IngestionProgressTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.IngestionProgress

  test "renders language-specific and default analyzer segments on ParadeDB" do
    summary = %{
      "total_chunks_detected" => 10,
      "total_chunks_indexed" => 7,
      "total_chunks_simple_indexed" => 2,
      "index_backend" => "parade_db",
      "detected_languages" => ["english", "japanese"],
      "errors" => [%{"chunk_index" => 9, "message" => "Embedding unavailable"}]
    }

    html = render_component(&IngestionProgress.ingestion_progress/1, summary: summary)

    assert html =~ ~s(role="progressbar")
    assert html =~ ~s(aria-valuenow="7")
    assert html =~ "5 language-specific"
    assert html =~ "2 default analyzer"
    assert html =~ "3 unindexed"
    assert html =~ "50.0%"
    assert html =~ "20.0%"
    assert html =~ "30.0%"
    assert html =~ "Japanese"
    assert html =~ "Embedding unavailable"
  end

  test "native simple fallback and legacy snapshots have honest labels" do
    summary = %{
      "total_chunks_detected" => 2,
      "total_chunks_indexed" => 2,
      "total_chunks_simple_indexed" => 2,
      "detected_languages" => ["french"]
    }

    native =
      render_component(&IngestionProgress.ingestion_progress/1,
        summary: Map.put(summary, "index_backend", "native")
      )

    parade =
      render_component(&IngestionProgress.ingestion_progress/1,
        summary: Map.put(summary, "index_backend", "parade_db")
      )

    legacy = render_component(&IngestionProgress.ingestion_progress/1, summary: summary)

    assert native =~ "2 simple fallback"
    assert parade =~ "2 default analyzer"
    assert parade =~ "French"
    assert parade =~ "0 language-specific"
    assert legacy =~ "2 language-neutral indexing"
  end

  test "zero and legacy totals never show a misleading 100%" do
    assert render_component(&IngestionProgress.ingestion_progress/1,
             summary: %{"total_chunks_detected" => 0}
           ) =~ "No chunks"

    assert render_component(&IngestionProgress.ingestion_progress/1, summary: %{}) =~
             "Unavailable"
  end
end
