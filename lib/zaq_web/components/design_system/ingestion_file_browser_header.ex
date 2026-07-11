defmodule ZaqWeb.Components.DesignSystem.IngestionFileBrowserHeader do
  @moduledoc """
  Toolbar actions for the BO ingestion file browser: folder actions, ingest mode, primary ingest CTA.

  **Layout / tokens:** sits in `.zaq-ingestion-chrome-row` beside the list/grid toggle; actions use
  `.zaq-ingestion-chrome-actions--end` for right alignment. `DesignSystem.Button` (`:secondary` folder/raw,
  `:primary` ingest) and tertiary mode chips in `assets/css/btn.css`.
  """

  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.Button

  attr :selected, :any, required: true
  attr :ingest_mode, :string, required: true
  attr :embedding_ready, :boolean, default: true
  attr :provider_mode, :boolean, default: false

  def file_browser_header(assigns) do
    ~H"""
    <div class="zaq-ingestion-chrome-actions zaq-ingestion-chrome-actions--end">
      <.button
        :if={not @provider_mode}
        id="new-folder-button"
        variant={:secondary}
        icon="hero-plus"
        phx-click="show_new_folder_modal"
      >
        New Folder
      </.button>
      <.button
        :if={not @provider_mode}
        id="add-raw-md-button"
        variant={:secondary}
        icon="hero-pencil-square"
        phx-click="show_add_raw_modal"
      >
        Add Raw MD
      </.button>
      <button
        :if={not @provider_mode and MapSet.size(@selected) > 0}
        id="bulk-delete-button"
        phx-click="show_delete_confirmation"
        class="zaq-btn zaq-btn-tertiary zaq-btn-danger zaq-btn-text_label-default"
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
        :if={not @provider_mode}
        id={"ingest-mode-#{mode}"}
        phx-click="set_mode"
        phx-value-mode={mode}
        type="button"
        class={[
          "zaq-btn zaq-btn-tertiary zaq-btn-text_label-default",
          @ingest_mode == mode && "zaq-btn-tertiary--active"
        ]}
      >
        {mode}
      </button>
      <.button
        id="ingest-selected-button"
        variant={:primary}
        phx-click="ingest_selected"
        disabled={MapSet.size(@selected) == 0 or not @embedding_ready}
      >
        Ingest Selected ({MapSet.size(@selected)})
      </.button>
    </div>
    """
  end
end
