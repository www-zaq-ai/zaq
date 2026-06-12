defmodule ZaqWeb.Components.DesignSystem.ModalRename do
  @moduledoc false
  use Phoenix.Component

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""

  def modal_rename(assigns) do
    ~H"""
    <div id="rename-modal" class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div
        phx-click-away="close_modal"
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-md overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl zaq-bg-accent-soft flex items-center justify-center shrink-0">
              <svg
                class="w-4.5 h-4.5 zaq-text-accent"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M15.232 5.232l3.536 3.536m-2.036-5.036a2.5 2.5 0 113.536 3.536L6.5 21.036H3v-3.572L16.732 3.732z"
                />
              </svg>
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">Rename</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Renaming <span class="text-black/60 font-medium">{@modal_name}</span>
              </p>
            </div>
          </div>
        </div>

        <form phx-submit="confirm_rename">
          <div class="px-6 pb-6">
            <div :if={@modal_error} class="mb-3 px-3 py-2 rounded-xl bg-red-50 border border-red-100">
              <p class="font-mono text-[0.72rem] text-red-500">{@modal_error}</p>
            </div>
            <label class="block font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-1.5">
              New Name
            </label>
            <input
              type="text"
              name="name"
              value={@modal_name}
              class="w-full font-mono text-[0.85rem] px-4 py-2.5 rounded-xl text-black border border-black/10 bg-[#fafafa] focus:border-[var(--zaq-color-accent)] focus:ring-2 focus:ring-[var(--zaq-color-accent-border)] outline-none transition-all"
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
              type="submit"
              class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-[var(--zaq-color-accent)] text-white hover:bg-[var(--zaq-color-accent-hover)] shadow-sm shadow-[var(--zaq-color-accent-border)] transition-all"
            >
              Rename
            </button>
          </div>
        </form>
      </div>
    </div>
    """
  end
end
