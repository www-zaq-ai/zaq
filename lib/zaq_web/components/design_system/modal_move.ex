defmodule ZaqWeb.Components.DesignSystem.ModalMove do
  @moduledoc """
  BO ingestion move-to-folder picker modal.
  """

  use Phoenix.Component

  attr :modal_error, :string, default: nil
  attr :modal_name, :string, default: ""
  attr :move_current_dir, :string, required: true
  attr :move_breadcrumbs, :list, required: true
  attr :move_folders, :list, required: true

  def modal_move(assigns) do
    ~H"""
    <div class="fixed inset-0 z-50 flex items-center justify-center p-4">
      <div
        phx-click-away="close_modal"
        phx-window-keydown="close_modal"
        phx-key="Escape"
        class="bg-white rounded-2xl shadow-2xl border border-black/[0.06] w-full max-w-lg overflow-hidden"
      >
        <div class="px-6 pt-6 pb-4">
          <div class="flex items-center gap-3 mb-1">
            <div class="w-9 h-9 rounded-xl bg-indigo-500/10 flex items-center justify-center shrink-0">
              <svg
                class="w-4.5 h-4.5 text-indigo-500"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
                />
                <path stroke-linecap="round" stroke-linejoin="round" d="M12 11v6m0 0l-2-2m2 2l2-2" />
              </svg>
            </div>
            <div>
              <h3 class="font-mono text-[0.9rem] font-semibold text-black">Move</h3>
              <p class="font-mono text-[0.72rem] text-black/40">
                Choose a destination for <span class="text-black/60 font-medium">{@modal_name}</span>
              </p>
            </div>
          </div>
        </div>

        <div class="px-6 pb-4">
          <div :if={@modal_error} class="mb-3 px-3 py-2 rounded-xl bg-red-50 border border-red-100">
            <p class="font-mono text-[0.72rem] text-red-500">{@modal_error}</p>
          </div>

          <div class="flex items-center gap-1.5 mb-3 font-mono text-[0.72rem]">
            <button
              :if={@move_current_dir != "."}
              phx-click="move_go_back"
              class="flex items-center justify-center w-5 h-5 rounded-md bg-black/5 text-black/40 hover:bg-black/10 hover:text-black/60 transition-colors shrink-0 mr-0.5"
              title="Go back"
            >
              <svg
                class="w-3 h-3"
                fill="none"
                stroke="currentColor"
                stroke-width="2.5"
                viewBox="0 0 24 24"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
              </svg>
            </button>
            <button
              phx-click="move_navigate"
              phx-value-path="."
              class="zaq-text-accent hover:underline"
            >
              root
            </button>
            <span :for={crumb <- @move_breadcrumbs} class="flex items-center gap-1">
              <span class="text-black/20">/</span>
              <button
                phx-click="move_navigate"
                phx-value-path={crumb.path}
                class="zaq-text-accent hover:underline"
              >
                {crumb.name}
              </button>
            </span>
          </div>

          <div class="mb-3 px-3 py-2 rounded-xl bg-indigo-50 border border-indigo-100">
            <p class="font-mono text-[0.7rem] text-indigo-600">
              Move to:
              <span class="font-semibold">
                {if @move_current_dir == ".", do: "root", else: @move_current_dir}
              </span>
            </p>
          </div>

          <div class="rounded-xl bg-[#fafafa] border border-black/[0.06] max-h-56 overflow-y-auto">
            <div :if={@move_folders == []} class="px-4 py-6 text-center">
              <p class="font-mono text-[0.75rem] text-black/30">No subfolders</p>
            </div>
            <div
              :for={folder <- @move_folders}
              phx-click="move_navigate"
              phx-value-path={Path.join(@move_current_dir, folder.name)}
              class="flex items-center gap-2.5 px-4 py-2.5 cursor-pointer transition-colors border-b border-black/[0.04] last:border-0 hover:bg-black/[0.02]"
            >
              <svg class="w-4 h-4 text-amber-400 shrink-0" fill="currentColor" viewBox="0 0 20 20">
                <path d="M2 6a2 2 0 012-2h5l2 2h5a2 2 0 012 2v6a2 2 0 01-2 2H4a2 2 0 01-2-2V6z" />
              </svg>
              <span class="font-mono text-[0.8rem] text-black truncate">{folder.name}</span>
              <svg
                class="w-3.5 h-3.5 text-black/20 ml-auto shrink-0"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M9 5l7 7-7 7" />
              </svg>
            </div>
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
            phx-click="confirm_move"
            class="font-mono text-[0.78rem] font-semibold px-5 py-2 rounded-xl bg-indigo-500 text-white hover:bg-indigo-600 shadow-sm shadow-indigo-500/20 transition-all"
          >
            Move Here
          </button>
        </div>
      </div>
    </div>
    """
  end
end
