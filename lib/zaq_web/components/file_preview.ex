defmodule ZaqWeb.Components.FilePreview do
  @moduledoc """
  Reusable BO file preview rendering blocks.
  """

  use ZaqWeb, :html

  import ZaqWeb.Helpers.DateFormat, only: [format_datetime: 1]

  alias ZaqWeb.Helpers.SizeFormat

  attr :preview, :map, required: true

  def meta(assigns) do
    ~H"""
    <div class="text-right">
      <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
        {SizeFormat.format_size(@preview.file_size)}
      </p>
      <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary)">
        {format_datetime(@preview.modified_at)}
      </p>
    </div>
    """
  end

  attr :preview, :map, required: true
  attr :pdf_height, :string, default: "80vh"

  def panel(assigns) do
    ~H"""
    <div
      :if={@preview.kind == :not_found}
      class="zaq-file-preview-shell zaq-file-preview-shell--inset text-center"
    >
      <svg
        class="zaq-file-preview-icon-muted mx-auto mb-3 h-10 w-10"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M12 9v2m0 4h.01M21 12a9 9 0 11-18 0 9 9 0 0118 0z"
        />
      </svg>
      <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
        File not found
      </p>
      <p class="zaq-text-caption mt-1" style="color: var(--zaq-text-color-body-tertiary)">
        {@preview.relative_path}
      </p>
    </div>

    <div :if={@preview.kind == :markdown} class="zaq-file-preview-shell">
      <div class="zaq-file-preview-bar zaq-file-preview-bar--rounded-top">
        <span class="zaq-pill zaq-text-caption zaq-pill--accent uppercase tracking-wide">
          {String.trim_leading(@preview.ext, ".")}
        </span>
        <span
          class="zaq-text-caption uppercase tracking-wide"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          rendered
        </span>
      </div>
      <div class="zaq-file-preview-body md-content max-w-none">
        {Phoenix.HTML.raw(@preview.rendered_html)}
      </div>
    </div>

    <div :if={@preview.kind == :text} class="zaq-file-preview-shell">
      <div class="zaq-file-preview-bar zaq-file-preview-bar--rounded-top">
        <span class="zaq-pill zaq-text-caption zaq-pill--elevated uppercase tracking-wide">
          {String.trim_leading(@preview.ext, ".")}
        </span>
        <span
          class="zaq-text-caption uppercase tracking-wide"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          plain text
        </span>
      </div>
      <pre class="zaq-text-pre zaq-file-preview-body">{@preview.content}</pre>
    </div>

    <div :if={@preview.kind == :image} class="zaq-file-preview-shell">
      <div class="zaq-file-preview-bar zaq-file-preview-bar--rounded-top">
        <span class="zaq-pill zaq-text-caption zaq-pill--elevated uppercase tracking-wide">
          {String.trim_leading(@preview.ext, ".")}
        </span>
        <span
          class="zaq-text-caption uppercase tracking-wide"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          image
        </span>
      </div>
      <div class="zaq-file-preview-media-well">
        <img src={@preview.raw_url} alt={@preview.filename} />
      </div>
    </div>

    <div :if={@preview.kind == :pdf} class="zaq-file-preview-shell overflow-hidden">
      <div class="zaq-file-preview-bar">
        <span class="zaq-pill zaq-text-caption zaq-pill--accent uppercase tracking-wide">
          pdf
        </span>
        <span
          class="zaq-text-caption uppercase tracking-wide"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          document
        </span>
      </div>
      <iframe
        src={@preview.raw_url}
        class="w-full"
        style={"height: #{@pdf_height};"}
        title={@preview.filename}
      />
    </div>

    <div
      :if={@preview.kind == :binary}
      class="zaq-file-preview-shell zaq-file-preview-shell--inset text-center"
    >
      <svg
        class="zaq-file-preview-icon-muted mx-auto mb-3 h-10 w-10"
        fill="none"
        stroke="currentColor"
        stroke-width="1.5"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M14 2H6a2 2 0 00-2 2v16a2 2 0 002 2h12a2 2 0 002-2V8z"
        />
        <polyline points="14 2 14 8 20 8" />
      </svg>
      <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
        Preview not available
      </p>
      <p class="zaq-text-caption mb-5 mt-1" style="color: var(--zaq-text-color-body-tertiary)">
        {String.trim_leading(@preview.ext, ".")} files cannot be previewed in the browser
      </p>
      <a
        href={@preview.raw_url}
        download={@preview.filename}
        class="zaq-btn zaq-btn-primary zaq-btn-text_label-default"
      >
        Download file
      </a>
    </div>
    """
  end
end
