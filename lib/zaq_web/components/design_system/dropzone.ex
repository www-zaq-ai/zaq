defmodule ZaqWeb.Components.DesignSystem.Dropzone do
  @moduledoc """
  BO ingestion upload drop zone, file queue, skipped-folder entries, and submit control.
  """

  use Phoenix.Component

  attr :uploads, :any, required: true
  attr :embedding_ready, :boolean, default: true
  attr :folder_drop_skipped, :list, default: []

  def upload_section(assigns) do
    ~H"""
    <div>
      <p class="zaq-text-caption zaq-ingestion-meta-label">Upload</p>
      <form id="upload-form" phx-submit="upload" phx-change="validate_upload">
        <div
          id="upload-drop-zone"
          class="zaq-dropzone"
          phx-drop-target={@uploads.files.ref}
          phx-hook="FolderDrop"
        >
          <div class="text-center">
            <div class="flex justify-center mb-2">
              <span style="color: var(--zaq-text-color-body-tertiary)" class="inline-flex">
                <svg
                  class="zaq-icon-sm"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.5"
                  viewBox="0 0 24 24"
                >
                  <path d="M7 16a4 4 0 01-.88-7.903A5 5 0 1115.9 6L16 6a5 5 0 011 9.9M15 13l-3-3m0 0l-3 3m3-3v12" />
                </svg>
              </span>
            </div>
            <p class="zaq-text-body-sm mb-1" style="color: var(--zaq-text-color-body-tertiary)">
              Drop files here or
              <label class="zaq-text-body-sm zaq-link-underline zaq-breadcrumb-crumb-link cursor-pointer">
                browse <.live_file_input upload={@uploads.files} class="hidden" />
              </label>
            </p>
            <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
              .md .txt .pdf .docx .pptx .xlsx .csv .png .jpg .jpeg — max 20 MB
            </p>
          </div>
        </div>

        <%= for entry <- @uploads.files.entries do %>
          <div class="mt-3 px-2">
            <div class="flex items-center justify-between">
              <span
                class="zaq-text-body-sm truncate max-w-[60%]"
                style="color: var(--zaq-text-color-body-default)"
              >
                {entry.client_name}
              </span>
              <div class="flex items-center gap-3">
                <div class="zaq-upload-progress-track w-32">
                  <div
                    class="zaq-upload-progress-fill"
                    style={"width: #{entry.progress}%;"}
                  />
                </div>
                <span class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
                  {entry.progress}%
                </span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="zaq-btn zaq-btn-icon zaq-btn-tertiary zaq-btn-danger transition-colors"
                  title="Remove"
                >
                  &times;
                </button>
              </div>
            </div>
            <%= for err <- Phoenix.Component.upload_errors(@uploads.files, entry) do %>
              <p class="zaq-text-caption mt-1" style="color: var(--zaq-text-color-body-danger)">
                {upload_error_message(err)}
              </p>
            <% end %>
          </div>
        <% end %>

        <div :if={@uploads.files.entries != []} style="margin-top: var(--zaq-scale-16)">
          <button
            id="upload-files-button"
            type="submit"
            disabled={not @embedding_ready}
            class="zaq-btn zaq-btn-primary zaq-btn-text_label-default"
          >
            Upload {length(@uploads.files.entries)} file(s)
          </button>
        </div>

        <div :if={@folder_drop_skipped != []} class="mt-3 space-y-1" data-testid="skipped-files">
          <p class="zaq-text-caption zaq-ingestion-meta-label">Skipped</p>
          <div :for={item <- @folder_drop_skipped} class="flex items-start gap-2">
            <span
              class="zaq-text-body-sm truncate max-w-[70%]"
              style="color: var(--zaq-text-color-body-warning)"
              title={item["path"]}
            >
              {item["name"]}
            </span>
            <span class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
              {skip_reason(item["reason"])}
            </span>
          </div>
        </div>
      </form>
    </div>
    """
  end

  def skip_reason("unsupported_format"), do: "unsupported format"
  def skip_reason(_), do: "skipped"

  defp upload_error_message(:too_large), do: "File exceeds 20 MB limit."
  defp upload_error_message(:not_accepted), do: "File type not supported."
  defp upload_error_message(:too_many_files), do: "Too many files selected (max 10)."
  defp upload_error_message(_), do: "Upload failed."
end
