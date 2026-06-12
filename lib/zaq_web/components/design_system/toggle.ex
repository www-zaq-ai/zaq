defmodule ZaqWeb.Components.DesignSystem.Toggle do
  @moduledoc """
  List / grid view switch and entry count for the BO ingestion file browser.

  **Styles:** universal block in `assets/css/styles.css` — `.zaq-toggle-*`,
  plus shared `.zaq-icon-sm` (not under the ingestion-only section).
  """

  use Phoenix.Component

  attr :view_mode, :string, required: true
  attr :entries, :list, required: true

  def toggle(assigns) do
    ~H"""
    <div class="zaq-toggle-row">
      <div class="zaq-toggle-group">
        <button
          phx-click="toggle_view_mode"
          phx-value-mode="list"
          type="button"
          class={[
            "zaq-toggle-segment",
            @view_mode == "list" && "zaq-toggle-segment--active"
          ]}
          title="List view"
        >
          <svg
            class="zaq-icon-sm"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M4 6h16M4 12h16M4 18h16" />
          </svg>
        </button>
        <button
          phx-click="toggle_view_mode"
          phx-value-mode="grid"
          type="button"
          class={[
            "zaq-toggle-segment",
            @view_mode == "grid" && "zaq-toggle-segment--active"
          ]}
          title="Grid view"
        >
          <svg
            class="zaq-icon-sm"
            fill="none"
            stroke="currentColor"
            stroke-width="2"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M4 5a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1V5zm10 0a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1V5zM4 15a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1H5a1 1 0 01-1-1v-4zm10 0a1 1 0 011-1h4a1 1 0 011 1v4a1 1 0 01-1 1h-4a1 1 0 01-1-1v-4z"
            />
          </svg>
        </button>
      </div>
      <span class="zaq-text-caption zaq-toggle-count">
        {length(@entries)} item(s)
      </span>
    </div>
    """
  end
end
