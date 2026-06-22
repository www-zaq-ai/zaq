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
    <div class="zaq-tab-nav">
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
      "zaq-tab-nav-item zaq-text-body",
      active_tab == tab_id && "zaq-tab-nav-item--active"
    ]
  end
end
