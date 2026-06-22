defmodule ZaqWeb.Components.DesignSystem.TabNav do
  @moduledoc """
  Segmented tab bar for BO master panels (e.g. People / Teams on `/bo/people`).

  Fires `phx-click` on each tab with `phx-value-tab` set to the tab id.
  Preserve `event` (default `switch_tab`) when wiring call sites so e2e selectors stay stable.
  """

  use Phoenix.Component

  attr :active_tab, :atom, required: true
  attr :tabs, :list, required: true, doc: "List of `%{id: atom(), label: String.t()}`"
  attr :event, :string, default: "switch_tab"

  def tab_nav(assigns) do
    ~H"""
    <div class="flex border-b border-black/8">
      <button
        :for={tab <- @tabs}
        type="button"
        phx-click={@event}
        phx-value-tab={tab.id}
        class={tab_button_class(@active_tab, tab.id)}
      >
        {tab.label}
      </button>
    </div>
    """
  end

  defp tab_button_class(active_tab, tab_id) do
    [
      "flex-1 font-mono text-[0.72rem] font-semibold py-3 transition-colors",
      active_tab == tab_id &&
        "zaq-text-accent border-b-2 border-[var(--zaq-color-accent)]",
      active_tab != tab_id && "text-black/40 hover:text-black/60"
    ]
  end
end
