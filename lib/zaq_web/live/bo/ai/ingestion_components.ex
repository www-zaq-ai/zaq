# lib/zaq_web/live/bo/ai/ingestion_components.ex

defmodule ZaqWeb.Live.BO.AI.IngestionComponents do
  @moduledoc """
  Function components for the Ingestion LiveView.
  """

  use Phoenix.Component
  use ZaqWeb, :verified_routes

  alias ZaqWeb.Components.BOModal
  alias ZaqWeb.Components.DesignSystem.Breadcrumb
  alias ZaqWeb.Components.DesignSystem.Dropzone
  alias ZaqWeb.Components.DesignSystem.IngestionEmbeddingBanner
  alias ZaqWeb.Components.DesignSystem.IngestionFileBrowserHeader
  alias ZaqWeb.Components.DesignSystem.IngestionFileGridView
  alias ZaqWeb.Components.DesignSystem.IngestionFileIcon
  alias ZaqWeb.Components.DesignSystem.IngestionFileListView
  alias ZaqWeb.Components.DesignSystem.IngestionJobsPanel
  alias ZaqWeb.Components.DesignSystem.IngestionVolumeSelector
  alias ZaqWeb.Components.DesignSystem.ModalAddRaw
  alias ZaqWeb.Components.DesignSystem.ModalDelete
  alias ZaqWeb.Components.DesignSystem.ModalDeleteSelected
  alias ZaqWeb.Components.DesignSystem.ModalMove
  alias ZaqWeb.Components.DesignSystem.ModalNewFolder
  alias ZaqWeb.Components.DesignSystem.ModalRename
  alias ZaqWeb.Components.DesignSystem.ModalShare
  alias ZaqWeb.Components.DesignSystem.ModalUpload
  alias ZaqWeb.Components.DesignSystem.StatusPill
  alias ZaqWeb.Components.DesignSystem.Toggle
  alias ZaqWeb.Helpers.SizeFormat

  # ── Helpers ──────────────────────────────────────────────────────────────

  defdelegate format_size(bytes), to: SizeFormat

  defdelegate file_icon(assigns), to: IngestionFileIcon
  defdelegate file_icon_color(name), to: IngestionFileIcon

  defdelegate status_pill_classes(status), to: StatusPill
  defdelegate folder_count_pill_classes(done?), to: StatusPill

  attr :volumes, :map, required: true
  attr :current_volume, :string, required: true
  attr :current_provider, :string, default: "local"
  attr :data_sources, :list, default: []

  def volume_selector(assigns) do
    IngestionVolumeSelector.volume_selector(assigns)
  end

  attr :selected, :any, required: true
  attr :ingest_mode, :string, required: true
  attr :embedding_ready, :boolean, default: true
  attr :provider_mode, :boolean, default: false
  attr :selected_watchable_count, :integer, default: 0
  attr :selected_watched_count, :integer, default: 0
  attr :watch_supported, :boolean, default: true
  attr :watch_disabled_reason, :string, default: nil

  def file_browser_header(assigns) do
    IngestionFileBrowserHeader.file_browser_header(assigns)
  end

  attr :breadcrumbs, :list, required: true
  attr :current_dir, :string, required: true

  def breadcrumb(assigns) do
    Breadcrumb.breadcrumb(assigns)
  end

  attr :value, :string, required: true
  attr :choices, :list, required: true
  attr :event, :string, required: true
  attr :value_param, :string, default: "value"
  attr :variant, :atom, default: :default, values: [:default, :pill]
  attr :suffix, :string, default: nil
  attr :class, :any, default: nil

  def toggle(assigns) do
    Toggle.toggle(assigns)
  end

  def ingestion_embedding_banner(assigns) do
    IngestionEmbeddingBanner.ingestion_embedding_banner(assigns)
  end

  # ── File List View ────────────────────────────────────────────────────────

  attr :entries, :list, required: true
  attr :selected, :any, required: true
  attr :current_dir, :string, required: true
  attr :current_volume, :string, required: true
  attr :ingestion_map, :map, required: true
  attr :provider_mode, :boolean, default: false
  attr :watch_supported, :boolean, default: true
  attr :watch_disabled_reason, :string, default: nil

  def file_list_view(assigns) do
    IngestionFileListView.file_list_view(assigns)
  end

  # ── File Grid View ────────────────────────────────────────────────────────

  attr :entries, :list, required: true
  attr :selected, :any, required: true
  attr :current_dir, :string, required: true
  attr :current_volume, :string, required: true
  attr :ingestion_map, :map, required: true
  attr :provider_mode, :boolean, default: false
  attr :watch_supported, :boolean, default: true
  attr :watch_disabled_reason, :string, default: nil

  def file_grid_view(assigns) do
    IngestionFileGridView.file_grid_view(assigns)
  end

  # ── Upload Section ────────────────────────────────────────────────────────

  defdelegate skip_reason(reason), to: Dropzone

  attr :uploads, :any, required: true
  attr :embedding_ready, :boolean, default: true
  attr :folder_drop_skipped, :list, default: []

  def upload_section(assigns) do
    Dropzone.upload_section(assigns)
  end

  # ── Jobs Panel ────────────────────────────────────────────────────────────

  attr :jobs, :list, required: true
  attr :status_filter, :string, required: true
  attr :prep_progress, :map, default: %{}

  def jobs_panel(assigns) do
    IngestionJobsPanel.jobs_panel(assigns)
  end

  # ── Modal: Add Raw MD ─────────────────────────────────────────────────────

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""
  attr :current_dir, :string, required: true

  def modal_add_raw(assigns) do
    ModalAddRaw.modal_add_raw(assigns)
  end

  # ── Modal: Rename ─────────────────────────────────────────────────────────

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""

  def modal_rename(assigns) do
    ModalRename.modal_rename(assigns)
  end

  # ── Modal: Delete Single ──────────────────────────────────────────────────

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""

  def modal_delete(assigns) do
    ModalDelete.modal_delete(assigns)
  end

  # ── Modal: Delete Selected ────────────────────────────────────────────────

  attr :selected, :any, required: true

  def modal_delete_selected(assigns) do
    ModalDeleteSelected.modal_delete_selected(assigns)
  end

  # ── Modal: New Folder ─────────────────────────────────────────────────────

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""

  def modal_new_folder(assigns) do
    ModalNewFolder.modal_new_folder(assigns)
  end

  # ── Modal: Upload ─────────────────────────────────────────────────────────

  attr :uploads, :any, required: true
  attr :embedding_ready, :boolean, default: true
  attr :folder_drop_skipped, :list, default: []

  def modal_upload(assigns) do
    ModalUpload.modal_upload(assigns)
  end

  # ── Modal: Move ───────────────────────────────────────────────────────────

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""
  attr :move_current_dir, :string, required: true
  attr :move_breadcrumbs, :list, required: true
  attr :move_folders, :list, required: true

  def modal_move(assigns) do
    ModalMove.modal_move(assigns)
  end

  # ── Share Modal ───────────────────────────────────────────────────────────

  attr :modal_name, :string, required: true
  attr :modal_error, :string, default: nil
  attr :share_modal_is_folder, :boolean, default: false
  attr :share_modal_is_public, :boolean, default: false
  attr :share_modal_original_is_public, :boolean, default: false
  attr :share_modal_permissions, :list, required: true
  attr :share_modal_targets_options, :list, required: true
  attr :share_modal_pending, :list, required: true
  attr :share_modal_read_only, :boolean, default: false
  attr :share_modal_notice, :string, default: nil

  def modal_share(assigns) do
    ModalShare.modal_share(assigns)
  end

  attr :modal_name, :string, required: true
  attr :watch_error_message, :string, required: true

  def modal_watch_error(assigns) do
    ~H"""
    <BOModal.form_dialog
      id="watch-error-modal"
      title="Watch setup failed"
      cancel_event="close_modal"
      max_width_class="max-w-md"
    >
      <div class="zaq-layout-stack-tight">
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
          Watching failed for <span class="font-semibold">{@modal_name}</span>.
        </p>
        <div
          class="rounded-xl border p-3"
          style="border-color: var(--zaq-border-color-danger); background: var(--zaq-surface-color-danger)"
        >
          <p
            class="zaq-text-body-sm whitespace-pre-wrap"
            style="color: var(--zaq-text-color-body-danger)"
          >
            {@watch_error_message}
          </p>
        </div>
      </div>
      <:actions>
        <button
          type="button"
          phx-click="close_modal"
          class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default"
        >
          Close
        </button>
        <button
          type="button"
          phx-click="retry_watch"
          class="zaq-btn zaq-btn-primary zaq-btn-text_label-default"
        >
          Retry
        </button>
      </:actions>
    </BOModal.form_dialog>
    """
  end
end
