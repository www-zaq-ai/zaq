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

  test "malformed indexed counters clamp to zero while preserving the total" do
    indexed_missing = %{
      "total_chunks_detected" => 10,
      "total_chunks_indexed" => nil,
      "total_chunks_simple_indexed" => 3
    }

    html = render_component(&IngestionProgress.ingestion_progress/1, summary: indexed_missing)
    assert html =~ ~s(aria-valuemin="0")
    assert html =~ ~s(aria-valuemax="10")
    assert html =~ ~s(aria-valuenow="0")

    assert html =~
             ~s(aria-valuetext="0 language-specific, 0 language-neutral indexing, 10 unindexed out of 10")

    assert html =~ ~s(class="zaq-ingestion-progress__specific" style="width: 0.0%")
    assert html =~ ~s(class="zaq-ingestion-progress__simple" style="width: 0.0%")

    assert html =~
             ~s|class="zaq-ingestion-progress__label--specific">0 language-specific (0.0%)</span>|

    assert html =~
             ~s|class="zaq-ingestion-progress__label--simple">0 language-neutral indexing (0.0%)</span>|

    assert html =~
             ~s|class="zaq-ingestion-progress__label--unindexed">10 unindexed (100.0%)</span>|

    simple_missing = %{
      "total_chunks_detected" => 10,
      "total_chunks_indexed" => 7,
      "total_chunks_simple_indexed" => "unknown"
    }

    html = render_component(&IngestionProgress.ingestion_progress/1, summary: simple_missing)
    assert html =~ ~s(aria-valuenow="7")

    assert html =~
             ~s(aria-valuetext="7 language-specific, 0 language-neutral indexing, 3 unindexed out of 10")

    assert html =~ ~s(class="zaq-ingestion-progress__specific" style="width: 70.0%")
    assert html =~ ~s(class="zaq-ingestion-progress__simple" style="width: 0.0%")

    assert html =~
             ~s|class="zaq-ingestion-progress__label--specific">7 language-specific (70.0%)</span>|

    assert html =~
             ~s|class="zaq-ingestion-progress__label--simple">0 language-neutral indexing (0.0%)</span>|

    assert html =~ ~s|class="zaq-ingestion-progress__label--unindexed">3 unindexed (30.0%)</span>|
  end

  test "simple and malformed language values render as undetermined" do
    summary = %{
      "total_chunks_detected" => 4,
      "total_chunks_indexed" => 4,
      "total_chunks_simple_indexed" => 1,
      "detected_languages" => ["simple", "english", nil, 42]
    }

    html = render_component(&IngestionProgress.ingestion_progress/1, summary: summary)
    assert html =~ ~s(aria-label="Detected languages")

    language_labels =
      Regex.scan(
        ~r/<span class="zaq-ingestion-progress__language">\s*(.*?)\s*<\/span>/s,
        html,
        capture: :all_but_first
      )
      |> Enum.map(&hd/1)

    assert language_labels == ["Undetermined", "English", "Undetermined", "Undetermined"]
  end
end
