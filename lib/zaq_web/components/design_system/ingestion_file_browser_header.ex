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
  attr :action_capabilities, :map, default: %{}
  attr :create_item_supported, :boolean, default: false
  attr :selected_watchable_count, :integer, default: 0
  attr :selected_watched_count, :integer, default: 0
  attr :watch_supported, :boolean, default: true
  attr :watch_disabled_reason, :string, default: nil
  attr :active_jobs_count, :integer, default: 0

  def file_browser_header(assigns) do
    ~H"""
    <div class="zaq-ingestion-chrome-actions zaq-ingestion-chrome-actions--end">
      <.button
        :if={@create_item_supported}
        id="upload-data-button"
        variant={:secondary}
        icon="hero-arrow-up-tray"
        phx-click="show_upload_modal"
      >
        Upload data
      </.button>
      <.button
        :if={@create_item_supported}
        id="new-folder-button"
        variant={:secondary}
        icon="hero-plus"
        phx-click="show_new_folder_modal"
      >
        New Folder
      </.button>
      <.button
        :if={@create_item_supported}
        id="add-raw-md-button"
        variant={:secondary}
        icon="hero-pencil-square"
        phx-click="show_add_raw_modal"
      >
        Add Raw MD
      </.button>
      <button
        :if={Map.get(@action_capabilities, :delete, false) and MapSet.size(@selected) > 0}
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
        :if={@selected_watchable_count > 0}
        id="bulk-watch-button"
        phx-click="watch_selected"
        class="zaq-btn zaq-btn-tertiary zaq-btn-text_label-default"
        type="button"
        disabled={not @watch_supported}
        title={if(not @watch_supported, do: @watch_disabled_reason)}
      >
        Watch ({@selected_watchable_count})
      </button>
      <button
        :if={@selected_watched_count > 0}
        id="bulk-unwatch-button"
        phx-click="unwatch_selected"
        class="zaq-btn zaq-btn-tertiary zaq-btn-text_label-default"
        type="button"
      >
        Unwatch ({@selected_watched_count})
      </button>
      <.button
        id="monitor-jobs-button"
        variant={:secondary}
        icon="hero-queue-list"
        phx-click="open_jobs_drawer"
      >
        Monitor jobs{active_jobs_label(@active_jobs_count)}
      </.button>
      <.button
        id="ingest-selected-button"
        variant={:primary}
        phx-click="ingest_selected"
        disabled={
          MapSet.size(@selected) == 0 or not @embedding_ready or
            not Map.get(@action_capabilities, :download, false)
        }
      >
        Ingest Selected ({MapSet.size(@selected)})
      </.button>
    </div>
    """
  end

  defp active_jobs_label(0), do: ""
  defp active_jobs_label(count), do: " (#{count} active)"
end
