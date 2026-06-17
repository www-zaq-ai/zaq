defmodule ZaqWeb.History.BulkSelectionBar do
  @moduledoc """
  Bulk actions bar when one or more conversations are selected on the history page.
  """

  use Phoenix.Component

  attr :selected_count, :integer, required: true, doc: "When zero, render nothing."
  attr :live_action, :atom, required: true, doc: "Hide Archive bulk action on archived route."

  def bulk_selection_bar(assigns) do
    ~H"""
    <div
      :if={@selected_count > 0}
      class="flex items-center gap-3 mb-4 px-4 py-2.5 bg-[#03b6d4]/5 border border-[#03b6d4]/20 rounded-xl"
    >
      <span class="font-mono text-[0.78rem] text-[#03b6d4]">
        {@selected_count} selected
      </span>
      <div class="flex-1" />
      <button
        :if={@live_action != :archived}
        type="button"
        phx-click="bulk_archive"
        class="font-mono text-[0.72rem] px-3 py-1.5 rounded-lg bg-black/5 text-black/60 hover:bg-black/10 transition-all"
      >
        Archive
      </button>
      <button
        type="button"
        phx-click="bulk_delete"
        data-confirm={"Delete #{@selected_count} conversation(s)? This cannot be undone."}
        class="font-mono text-[0.72rem] px-3 py-1.5 rounded-lg bg-red-50 text-red-600 hover:bg-red-100 transition-all"
      >
        Delete
      </button>
    </div>
    """
  end
end
