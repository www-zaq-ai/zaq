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
      <p class="font-mono text-[0.68rem] text-black/30">
        {SizeFormat.format_size(@preview.file_size)}
      </p>
      <p class="font-mono text-[0.65rem] text-black/25">{format_datetime(@preview.modified_at)}</p>
    </div>
    """
  end

  attr :preview, :map, required: true
  attr :pdf_height, :string, default: "80vh"

  def panel(assigns) do
    ~H"""
    <div
      :if={@preview.kind == :not_found}
      class="bg-white rounded-2xl border border-black/[0.06] shadow-sm p-16 text-center"
    >
      <svg
        class="w-10 h-10 mx-auto mb-3 text-black/15"
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
      <p class="font-mono text-[0.85rem] text-black/40">File not found</p>
      <p class="font-mono text-[0.72rem] text-black/25 mt-1">{@preview.relative_path}</p>
    </div>

    <div
      :if={@preview.kind == :markdown}
      class="bg-white rounded-2xl border border-black/[0.06] shadow-sm"
    >
      <div class="flex items-center gap-2 px-6 py-3 border-b border-black/[0.06] bg-[#fafafa] rounded-t-2xl">
        <span class="font-mono text-[0.65rem] px-2 py-0.5 rounded-lg bg-[#03b6d4]/10 text-[#03b6d4]">
          {String.trim_leading(@preview.ext, ".")}
        </span>
        <span class="font-mono text-[0.65rem] text-black/25">rendered</span>
      </div>
      <div class="px-10 py-8 md-content max-w-none">
        {Phoenix.HTML.raw(@preview.rendered_html)}
      </div>
    </div>

    <div
      :if={@preview.kind == :text}
      class="bg-white rounded-2xl border border-black/[0.06] shadow-sm"
    >
      <div class="flex items-center gap-2 px-6 py-3 border-b border-black/[0.06] bg-[#fafafa] rounded-t-2xl">
        <span class="font-mono text-[0.65rem] px-2 py-0.5 rounded-lg bg-black/5 text-black/40">
          {String.trim_leading(@preview.ext, ".")}
        </span>
        <span class="font-mono text-[0.65rem] text-black/25">plain text</span>
      </div>
      <pre class="px-8 py-6 font-mono text-[0.82rem] text-black/70 whitespace-pre-wrap break-words overflow-x-auto leading-relaxed">{@preview.content}</pre>
    </div>

    <div
      :if={@preview.kind == :image}
      class="bg-white rounded-2xl border border-black/[0.06] shadow-sm"
    >
      <div class="flex items-center gap-2 px-6 py-3 border-b border-black/[0.06] bg-[#fafafa] rounded-t-2xl">
        <span class="font-mono text-[0.65rem] px-2 py-0.5 rounded-lg bg-black/5 text-black/40">
          {String.trim_leading(@preview.ext, ".")}
        </span>
        <span class="font-mono text-[0.65rem] text-black/25">image</span>
      </div>
      <div class="p-8 flex items-center justify-center bg-[#fafafa] rounded-b-2xl">
        <img
          src={@preview.raw_url}
          alt={@preview.filename}
          class="max-w-full max-h-[70vh] rounded-xl shadow-sm object-contain"
        />
      </div>
    </div>

    <div
      :if={@preview.kind == :pdf}
      class="bg-white rounded-2xl border border-black/[0.06] shadow-sm overflow-hidden"
    >
      <div class="flex items-center gap-2 px-6 py-3 border-b border-black/[0.06] bg-[#fafafa]">
        <span class="font-mono text-[0.65rem] px-2 py-0.5 rounded-lg bg-red-100 text-red-500">
          pdf
        </span>
        <span class="font-mono text-[0.65rem] text-black/25">document</span>
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
      class="bg-white rounded-2xl border border-black/[0.06] shadow-sm p-16 text-center"
    >
      <svg
        class="w-10 h-10 mx-auto mb-3 text-black/15"
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
      <p class="font-mono text-[0.85rem] text-black/40">Preview not available</p>
      <p class="font-mono text-[0.72rem] text-black/25 mt-1 mb-5">
        {String.trim_leading(@preview.ext, ".")} files cannot be previewed in the browser
      </p>
      <a
        href={@preview.raw_url}
        download={@preview.filename}
        class="font-mono text-[0.78rem] font-semibold px-5 py-2.5 rounded-xl bg-[#03b6d4] text-white hover:bg-[#029ab3] shadow-sm shadow-[#03b6d4]/20 transition-all"
      >
        Download file
      </a>
    </div>
    """
  end
end
