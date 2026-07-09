defmodule ZaqWeb.Components.BOFileUpload do
  @moduledoc """
  Shared file upload drop-zone component for BO pages.

  Renders a styled drag-and-drop area with a hidden file input. Works with
  Phoenix LiveView uploads (`allow_upload/3`). The wrapping `<form>` and any
  submit button are the caller's responsibility.

  ## Usage

      <BOFileUpload.drop_zone
        upload={@uploads.files}
        id="upload-drop-zone"
        hook="FolderDrop"
        accept_label=".md .txt .pdf — max 20 MB"
      />
  """

  use Phoenix.Component

  attr :upload, :any, required: true
  attr :id, :string, default: "file-drop-zone"
  attr :accept_label, :string, default: nil
  attr :hook, :string, default: nil

  def drop_zone(assigns) do
    ~H"""
    <div
      id={@id}
      class="bg-white rounded-2xl border-2 border-dashed border-black/10 hover:border-[var(--zaq-color-accent)] transition-colors p-6"
      phx-drop-target={@upload.ref}
      phx-hook={@hook}
    >
      <div class="text-center">
        <svg
          class="w-8 h-8 mx-auto mb-2 text-black/20"
          fill="none"
          stroke="currentColor"
          stroke-width="1.5"
          viewBox="0 0 24 24"
        >
          <path d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12" />
        </svg>
        <p class="font-mono text-[0.8rem] text-black/40 mb-1">
          Drop file here or
          <label class="zaq-text-accent hover:underline cursor-pointer">
            browse <.live_file_input upload={@upload} class="hidden" />
          </label>
        </p>
        <p :if={@accept_label} class="font-mono text-[0.65rem] text-black/40">
          {@accept_label}
        </p>
      </div>
    </div>
    """
  end
end
