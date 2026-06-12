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
      <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-3">Upload</p>
      <form id="upload-form" phx-submit="upload" phx-change="validate_upload">
        <div
          id="upload-drop-zone"
          class="bg-white rounded-2xl border-2 border-dashed border-black/10 hover:border-[var(--zaq-color-accent)] transition-colors p-6"
          phx-drop-target={@uploads.files.ref}
          phx-hook="FolderDrop"
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
              Drop files here or
              <label class="zaq-text-accent hover:underline cursor-pointer">
                browse <.live_file_input upload={@uploads.files} class="hidden" />
              </label>
            </p>
            <p class="font-mono text-[0.65rem] text-black/40">
              .md .txt .pdf .docx .pptx .xlsx .csv .png .jpg .jpeg — max 20 MB
            </p>
          </div>
        </div>

        <%= for entry <- @uploads.files.entries do %>
          <div class="mt-3 px-2">
            <div class="flex items-center justify-between">
              <span class="font-mono text-[0.8rem] text-black truncate max-w-[60%]">
                {entry.client_name}
              </span>
              <div class="flex items-center gap-3">
                <div class="w-32 h-1.5 bg-black/5 rounded-full overflow-hidden">
                  <div
                    class="h-full bg-[var(--zaq-color-accent)] rounded-full transition-all"
                    style={"width: #{entry.progress}%;"}
                  />
                </div>
                <span class="font-mono text-[0.7rem] text-black/40">{entry.progress}%</span>
                <button
                  type="button"
                  phx-click="cancel_upload"
                  phx-value-ref={entry.ref}
                  class="text-black/30 hover:text-red-400 transition-colors"
                  title="Remove"
                >
                  &times;
                </button>
              </div>
            </div>
            <%= for err <- Phoenix.Component.upload_errors(@uploads.files, entry) do %>
              <p class="font-mono text-[0.7rem] text-red-500 mt-1">
                {upload_error_message(err)}
              </p>
            <% end %>
          </div>
        <% end %>

        <button
          :if={@uploads.files.entries != []}
          id="upload-files-button"
          type="submit"
          disabled={not @embedding_ready}
          class={[
            "mt-4 font-mono text-[0.78rem] font-bold px-5 py-2 rounded-xl transition-all",
            if(@embedding_ready,
              do:
                "bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)] shadow-sm shadow-[var(--zaq-color-accent-border)]",
              else: "bg-black/5 text-black/20 cursor-not-allowed"
            )
          ]}
        >
          Upload {length(@uploads.files.entries)} file(s)
        </button>

        <div :if={@folder_drop_skipped != []} class="mt-3 space-y-1" data-testid="skipped-files">
          <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider">Skipped</p>
          <div :for={item <- @folder_drop_skipped} class="flex items-start gap-2">
            <span
              class="font-mono text-[0.75rem] text-amber-600 truncate max-w-[70%]"
              title={item["path"]}
            >
              {item["name"]}
            </span>
            <span class="font-mono text-[0.65rem] text-black/30">{skip_reason(item["reason"])}</span>
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
