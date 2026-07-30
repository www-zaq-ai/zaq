defmodule ZaqWeb.Components.DesignSystem.Dropzone do
  @moduledoc """
  BO upload drop zone, file queue, skipped-folder entries, and submit control.

  Originally built for the ingestion page and still defaulting to its ids, events and
  copy, so `IngestionLive` renders identically without passing anything. Every one of
  those is an optional attr, because a second LiveView (the skills page) needs the same
  markup wired to its own events — and two dropzones in one DOM must not share element
  ids. Configure it; do not fork it.
  """

  use Phoenix.Component

  attr :uploads, :any, required: true
  attr :embedding_ready, :boolean, default: true
  attr :folder_drop_skipped, :list, default: []

  attr :upload_name, :atom, default: :files, doc: "Key of the `allow_upload/3` config."

  attr :id_prefix, :string,
    default: "upload",
    doc: "Prefix for `-form`, `-drop-zone` and `-files-button` element ids."

  attr :submit_event, :string, default: "upload"
  attr :change_event, :string, default: "validate_upload"
  attr :cancel_event, :string, default: "cancel_upload"
  attr :label, :string, default: "Upload"
  attr :submit_label, :string, default: "Upload", doc: "Verb on the submit button."

  attr :hint, :string, default: ".md .txt .pdf .docx .pptx .xlsx .csv .png .jpg .jpeg — max 20 MB"

  attr :folder_drop?, :boolean,
    default: true,
    doc: "Attaches the FolderDrop JS hook, which expands dropped directories."

  def upload_section(assigns) do
    assigns = assign(assigns, :upload, Map.fetch!(assigns.uploads, assigns.upload_name))

    ~H"""
    <div>
      <p class="zaq-text-caption zaq-ingestion-meta-label">{@label}</p>
      <form id={"#{@id_prefix}-form"} phx-submit={@submit_event} phx-change={@change_event}>
        <div
          id={"#{@id_prefix}-drop-zone"}
          class="zaq-dropzone"
          phx-drop-target={@upload.ref}
          phx-hook={if @folder_drop?, do: "FolderDrop"}
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
                browse <.live_file_input upload={@upload} class="hidden" />
              </label>
            </p>
            <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
              {@hint}
            </p>
          </div>
        </div>

        <%= for entry <- @upload.entries do %>
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
                  phx-click={@cancel_event}
                  phx-value-ref={entry.ref}
                  class="zaq-btn zaq-btn-icon zaq-btn-tertiary zaq-btn-danger transition-colors"
                  title="Remove"
                >
                  &times;
                </button>
              </div>
            </div>
            <%= for err <- Phoenix.Component.upload_errors(@upload, entry) do %>
              <p class="zaq-text-caption mt-1" style="color: var(--zaq-text-color-body-danger)">
                {upload_error_message(err)}
              </p>
            <% end %>
          </div>
        <% end %>

        <div :if={@upload.entries != []} style="margin-top: var(--zaq-scale-16)">
          <button
            id={"#{@id_prefix}-files-button"}
            type="submit"
            disabled={not @embedding_ready}
            class="zaq-btn zaq-btn-primary zaq-btn-text_label-default"
          >
            {@submit_label} {length(@upload.entries)} file(s)
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
