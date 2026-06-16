defmodule ZaqWeb.Components.FilePreviewModal do
  @moduledoc """
  Reusable file preview modal for BO LiveViews.
  """

  use ZaqWeb, :html

  attr :id, :string, default: "file-preview-modal"
  attr :cancel_event, :string, default: "close_preview_modal"
  attr :preview, :map, required: true

  def modal(assigns) do
    ~H"""
    <ZaqWeb.Components.BOModal.modal_shell
      id={@id}
      cancel_event={@cancel_event}
      max_width_class="max-w-6xl"
      panel_base_class="zaq-modal zaq-modal--flush"
    >
      <div class="zaq-file-preview-bar justify-between">
        <div class="min-w-0">
          <p class="zaq-text-h4 truncate">{@preview.filename}</p>
          <p
            class="zaq-text-caption mt-0.5 truncate"
            style="color: var(--zaq-text-color-body-tertiary)"
          >
            {@preview.relative_path}
          </p>
        </div>

        <div class="flex items-center gap-3">
          <ZaqWeb.Components.FilePreview.meta preview={@preview} />

          <a
            :if={@preview.raw_url}
            href={@preview.raw_url}
            target="_blank"
            rel="noopener noreferrer"
            class="zaq-btn zaq-btn-secondary zaq-btn-text_label-default"
            title="Open raw file"
          >
            <.icon name="hero-arrow-top-right-on-square" class="h-4 w-4" /> Raw
          </a>

          <button
            type="button"
            phx-click={@cancel_event}
            class="zaq-btn zaq-btn-icon zaq-btn-secondary"
            title="Close"
          >
            <.icon name="hero-x-mark" class="h-4 w-4" />
          </button>
        </div>
      </div>

      <div class="zaq-file-preview-scroll">
        <ZaqWeb.Components.FilePreview.panel preview={@preview} pdf_height="68vh" />
      </div>
    </ZaqWeb.Components.BOModal.modal_shell>
    """
  end
end
