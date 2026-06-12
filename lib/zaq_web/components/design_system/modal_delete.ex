defmodule ZaqWeb.Components.DesignSystem.ModalDelete do
  @moduledoc false
  use Phoenix.Component

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""

  def modal_delete(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div
        phx-click-away="close_modal"
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-md overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl bg-red-500/10 flex items-center justify-center shrink-0">
              <svg
                class="w-4.5 h-4.5 text-red-500"
                fill="none"
                stroke="currentColor"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  stroke-width="2"
                  d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
                />
              </svg>
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">Delete</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Permanently delete <span class="text-black/60 font-medium">{@modal_name}</span>
              </p>
            </div>
          </div>
        </div>
        <div :if={@modal_error} class="px-6 pt-2 pb-0">
          <div class="px-3 py-2 rounded-xl bg-red-50 border border-red-100">
            <p class="font-mono text-[0.72rem] text-red-500">{@modal_error}</p>
          </div>
        </div>
        <div class="px-6 py-4 bg-[#fafafa] border-t border-black/[0.06] flex items-center justify-end gap-2">
          <button
            phx-click="close_modal"
            class="font-mono text-[0.78rem] px-4 py-2 rounded-xl text-black/50 hover:bg-black/5 transition-colors"
          >
            Cancel
          </button>
          <button
            phx-click="confirm_delete"
            class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-red-500 text-white hover:bg-red-600 shadow-sm shadow-red-500/20 transition-all"
          >
            Delete
          </button>
        </div>
      </div>
    </div>
    """
  end
end
