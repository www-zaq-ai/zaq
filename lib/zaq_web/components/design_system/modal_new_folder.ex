defmodule ZaqWeb.Components.DesignSystem.ModalNewFolder do
  @moduledoc false
  use Phoenix.Component

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""

  def modal_new_folder(assigns) do
    ~H"""
    <div id="new-folder-modal" class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div
        phx-click-away="close_modal"
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-md overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl bg-amber-500/10 flex items-center justify-center shrink-0">
              <svg class="w-4.5 h-4.5 text-amber-500" fill="currentColor" viewBox="0 0 20 20">
                <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z" />
              </svg>
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">New Folder</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Create a new folder in the current directory
              </p>
            </div>
          </div>
        </div>

        <form id="new-folder-form" phx-submit="create_folder">
          <div class="px-6 pb-6">
            <div :if={@modal_error} class="mb-3 px-3 py-2 rounded-xl bg-red-50 border border-red-100">
              <p class="font-mono text-[0.72rem] text-red-500">{@modal_error}</p>
            </div>
            <label class="block font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-1.5">
              Folder Name
            </label>
            <input
              id="new-folder-input"
              type="text"
              name="name"
              value={@modal_name}
              phx-hook="FocusAndSelect"
              placeholder="my-folder"
              class="w-full font-mono text-[0.85rem] px-4 py-2.5 rounded-xl text-black border border-black/10 bg-[#fafafa] focus:border-[var(--zaq-color-accent)] focus:ring-2 focus:ring-[var(--zaq-color-accent-border)] outline-none transition-all placeholder:text-black/20"
            />
          </div>
          <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] flex items-center justify-end gap-2">
            <button
              type="button"
              phx-click="close_modal"
              class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
            >
              Cancel
            </button>
            <button
              id="create-folder-button"
              type="submit"
              class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)] shadow-sm shadow-[var(--zaq-color-accent-border)] transition-all"
            >
              Create
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
