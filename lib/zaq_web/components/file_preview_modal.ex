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
      panel_class="p-0 overflow-hidden"
    >
      <div class="flex items-center justify-between px-6 py-4 border-b border-black/[0.06] bg-[#fafafa]">
        <div class="min-w-0">
          <p class="font-mono text-[0.9rem] font-semibold text-black truncate">{@preview.filename}</p>
          <p class="font-mono text-[0.68rem] text-black/35 mt-0.5 truncate">
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
            class="font-mono text-[0.72rem] px-3 py-1.5 rounded-xl bg-black/5 text-black/50 hover:bg-black/10 transition-colors flex items-center gap-1.5"
            title="Open raw file"
          >
            <.icon name="hero-arrow-top-right-on-square" class="w-3.5 h-3.5" /> Raw
          </a>

          <button
            type="button"
            phx-click={@cancel_event}
            class="p-2 rounded-lg text-black/35 hover:text-black/60 hover:bg-black/5 transition-colors"
            title="Close"
          >
            <.icon name="hero-x-mark" class="w-4 h-4" />
          </button>
        </div>
      </div>

      <div class="max-h-[80vh] overflow-auto p-6 bg-[#f7f6f3]">
        <ZaqWeb.Components.FilePreview.panel preview={@preview} pdf_height="68vh" />
      </div>
    </ZaqWeb.Components.BOModal.modal_shell>
    """
  end
end
