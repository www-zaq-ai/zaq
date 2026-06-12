defmodule ZaqWeb.Components.DesignSystem.ModalAddRaw do
  @moduledoc false
  use Phoenix.Component

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""
  attr :current_dir, :string, required: true

  def modal_add_raw(assigns) do
    ~H"""
    <div id="add-raw-modal" class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div class="fixed inset-0 bg-black/20 backdrop-blur-sm" phx-click="close_modal" />
      <div
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="relative bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-2xl overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl zaq-bg-accent-soft flex items-center justify-center shrink-0">
              <svg
                class="w-4.5 h-4.5 zaq-text-accent"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M11 5H6a2 2 0 00-2 2v11a2 2 0 002 2h11a2 2 0 002-2v-5m-1.414-9.414a2 2 0 112.828 2.828L11.828 15H9v-2.828l8.586-8.586z"
                />
              </svg>
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">Add Raw MD Content</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Paste or type Markdown — saved as a <span class="text-black/60 font-medium">.md</span>
                file in the current directory
              </p>
            </div>
          </div>
        </div>

        <form id="add-raw-form" phx-submit="add_raw_content">
          <div class="px-6 pb-6 space-y-4">
            <div :if={@modal_error} class="px-3 py-2 rounded-xl bg-red-50 border border-red-100">
              <p class="font-mono text-[0.72rem] text-red-500">{@modal_error}</p>
            </div>

            <div>
              <label class="block font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-1.5">
                Filename
              </label>
              <div class="flex items-center gap-2">
                <input
                  id="raw-filename-input"
                  type="text"
                  name="filename"
                  value={@modal_name}
                  phx-hook="FocusAndSelect"
                  placeholder="my-document"
                  class="flex-1 font-mono text-[0.85rem] px-4 py-2.5 rounded-xl text-black border border-black/10 bg-[#fafafa] focus:border-[var(--zaq-color-accent)] focus:ring-2 focus:ring-[var(--zaq-color-accent-border)] outline-none transition-all placeholder:text-black/20"
                />
                <span class="font-mono text-[0.8rem] text-black/30 shrink-0">.md</span>
              </div>
            </div>

            <div>
              <label class="block font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-1.5">
                Content
              </label>
              <textarea
                id="raw-content-input"
                name="content"
                rows="14"
                placeholder="# My Document&#10;&#10;Start writing your Markdown here..."
                class="w-full font-mono text-[0.82rem] px-4 py-3 rounded-xl text-black border border-black/10 bg-[#fafafa] focus:border-[var(--zaq-color-accent)] focus:ring-2 focus:ring-[var(--zaq-color-accent-border)] outline-none transition-all placeholder:text-black/20 resize-none"
              ></textarea>
            </div>
          </div>

          <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] flex items-center justify-between">
            <p class="font-mono text-[0.68rem] text-black/30">
              Saving to:
              <span class="text-black/50">
                {if @current_dir == ".", do: "root", else: @current_dir}/
              </span>
            </p>
            <div class="flex items-center gap-2">
              <button
                type="button"
                phx-click="close_modal"
                class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
              >
                Cancel
              </button>
              <button
                id="save-raw-file-button"
                type="submit"
                class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)] shadow-sm shadow-[var(--zaq-color-accent-border)] transition-all"
              >
                Save File
              </button>
            </div>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
