defmodule ZaqWeb.Components.DesignSystem.IngestionNoSourceNotice do
  @moduledoc """
  Notice shown on the ingestion page when no data source is enabled.

  Points the operator at the data sources page, which is the only place a source — the server
  disk included — is turned on.
  """

  use Phoenix.Component

  def ingestion_no_source_notice(assigns) do
    ~H"""
    <div class="zaq-feedback-banner zaq-warning zaq-text-body">
      <span class="zaq-feedback-icon">
        <svg fill="none" stroke="currentColor" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            stroke-width="2"
            d="M20 7c0 1.657-3.582 3-8 3s-8-1.343-8-3m16 0c0-1.657-3.582-3-8-3S4 5.343 4 7m16 0v10c0 1.657-3.582 3-8 3s-8-1.343-8-3V7"
          />
        </svg>
      </span>
      <div class="zaq-feedback-body">
        <p class="font-semibold" data-testid="no-data-source-title">No data source enabled</p>
        <p>
          Enable a data source — the server disk, Google Drive, SharePoint — to browse and ingest
          documents.
          <a href="/bo/channels/data_source" class="zaq-link-underline">
            Go to Data sources →
          </a>
        </p>
      </div>
    </div>
    """
  end
end
