defmodule ZaqWeb.Components.DesignSystem.SimplePagination do
  @moduledoc """
  Range label with optional Prev/Next controls for BO list panels.

  Used on `/bo/people` and similar paginated master lists. Prev/Next buttons render
  only when another page exists in that direction.
  """

  use Phoenix.Component

  attr :page, :integer, required: true
  attr :per_page, :integer, required: true
  attr :total_count, :integer, required: true
  attr :change_event, :string, default: "change_page"

  def simple_pagination(assigns) do
    ~H"""
    <div
      :if={@total_count > 0}
      class="px-5 py-3 border-t border-black/6 flex items-center justify-between"
    >
      <span class="font-mono text-[0.68rem] text-black/40">
        {@page * @per_page - @per_page + 1}–{min(@page * @per_page, @total_count)} of {@total_count}
      </span>
      <div class="flex gap-1">
        <button
          :if={@page > 1}
          type="button"
          phx-click={@change_event}
          phx-value-page={@page - 1}
          class="font-mono text-[0.7rem] px-3 py-1.5 rounded-lg border border-black/12 text-black/60 hover:bg-black/5 transition-colors"
        >
          ← Prev
        </button>
        <button
          :if={@page * @per_page < @total_count}
          type="button"
          phx-click={@change_event}
          phx-value-page={@page + 1}
          class="font-mono text-[0.7rem] px-3 py-1.5 rounded-lg border border-black/12 text-black/60 hover:bg-black/5 transition-colors"
        >
          Next →
        </button>
      </div>
    </div>
    """
  end
end
