defmodule ZaqWeb.Components.DesignSystem.IngestionFileBrowserHeader do
  @moduledoc """
  Toolbar for the BO ingestion file browser: labels, folder actions, ingest mode, primary ingest CTA.

  **Layout / tokens:** same ingestion chrome band as `IngestionVolumeSelector` in `assets/css/styles.css`
  (`.zaq-ingestion-chrome-row--spaced`, `.zaq-ingestion-chrome-actions`, `.zaq-ingestion-meta-label`, `.zaq-ingestion-chip*`, `.zaq-icon-sm`, `.zaq-btn*`)
  with `.zaq-text-caption` from `text-styles.css` for chip and meta label type (per design-migrate: no new text stacks in `styles.css`).
  """

  use Phoenix.Component

  attr :selected, :any, required: true
  attr :ingest_mode, :string, required: true
  attr :embedding_ready, :boolean, default: true

  def file_browser_header(assigns) do
    ~H"""
    <div class="zaq-ingestion-chrome-row zaq-ingestion-chrome-row--spaced">
      <p class="zaq-ingestion-meta-label zaq-text-caption zaq-ingestion-meta-label--push">
        File Browser
      </p>
      <div class="zaq-ingestion-chrome-actions">
        <button
          id="new-folder-button"
          phx-click="show_new_folder_modal"
          class="zaq-ingestion-chip zaq-text-caption"
          type="button"
        >
          <svg class="zaq-icon-sm" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M12 4v16m8-8H4" />
          </svg>
          New Folder
        </button>
        <button
          id="add-raw-md-button"
          phx-click="show_add_raw_modal"
          class="zaq-ingestion-chip zaq-text-caption"
          type="button"
        >
          <svg class="zaq-icon-sm" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
            />
          </svg>
          Add Raw MD
        </button>
        <button
          :if={MapSet.size(@selected) > 0}
          id="bulk-delete-button"
          phx-click="show_delete_confirmation"
          class="zaq-ingestion-chip zaq-ingestion-chip--danger zaq-text-caption"
          type="button"
        >
          <svg class="zaq-icon-sm" fill="none" stroke="currentColor" viewBox="0 0 24 24">
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              stroke-width="2"
              d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
            />
          </svg>
          Delete ({MapSet.size(@selected)})
        </button>
        <button
          :for={mode <- ~w(async inline)}
          id={"ingest-mode-#{mode}"}
          phx-click="set_mode"
          phx-value-mode={mode}
          type="button"
          class={[
            "zaq-ingestion-chip zaq-text-caption",
            @ingest_mode == mode && "zaq-ingestion-chip--active"
          ]}
        >
          {mode}
        </button>
        <button
          id="ingest-selected-button"
          phx-click="ingest_selected"
          disabled={MapSet.size(@selected) == 0 or not @embedding_ready}
          type="button"
          class="zaq-btn zaq-btn-primary zaq-btn-text_label-default"
        >
          Ingest Selected ({MapSet.size(@selected)})
        </button>
      </div>
    </div>
    """
  end
end
