defmodule Storybook.Ingestion.IngestionProgress do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.IngestionProgress

  def description,
    do: "Per-document indexing progress: language-specific, language-neutral and unindexed chunks."

  def render(assigns) do
    ~H"""
    <div class="zaq-text-body flex flex-col gap-8" style="padding: var(--zaq-scale-32); max-width: 400px;">
      <section>
        <h2>Partially indexed; one unsupported language uses simple</h2>
        <.ingestion_progress
          summary={%{
            "total_chunks_detected" => 10,
            "total_chunks_indexed" => 8,
            "total_chunks_simple_indexed" => 3,
            "index_backend" => "native",
            "detected_languages" => ["english", "hindi", "japanese"],
            "errors" => [%{"chunk_index" => 9, "message" => "Embedding unavailable"}]
          }}
        />
      </section>
      <section>
        <h2>ParadeDB default analyzer with detected French</h2>
        <.ingestion_progress
          summary={%{
            "index_backend" => "parade_db",
            "total_chunks_detected" => 3,
            "total_chunks_indexed" => 3,
            "total_chunks_simple_indexed" => 3,
            "detected_languages" => ["french"],
            "errors" => []
          }}
        />
      </section>
      <section>
        <h2>Empty document</h2>
        <.ingestion_progress summary={%{"total_chunks_detected" => 0}} />
      </section>
      <section>
        <h2>Legacy document</h2>
        <.ingestion_progress summary={%{}} />
      </section>
    </div>
    """
  end
end
