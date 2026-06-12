defmodule ZaqWeb.Components.DesignSystem.IngestionEmbeddingBanner do
  @moduledoc """
  Warning shown on the ingestion page when embedding is not configured.
  """

  use Phoenix.Component

  def ingestion_embedding_banner(assigns) do
    ~H"""
    <div class="zaq-feedback-banner zaq-warning zaq-text-body">
      <span class="zaq-feedback-icon">
        <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M12 9v2m0 4h.01M10.29 3.86L1.82 18a2 2 0 001.71 3h16.94a2 2 0 001.71-3L13.71 3.86a2 2 0 00-3.42 0z"
          />
        </svg>
      </span>
      <div class="zaq-feedback-body">
        <p class="font-semibold" data-testid="embedding-warning-title">Embedding not configured</p>
        <p>
          Please configure and save your embedding settings before ingesting documents.
          <a href="/bo/system-config?tab=embedding" class="zaq-link-underline">
            Go to Settings →
          </a>
        </p>
      </div>
    </div>
    """
  end
end
