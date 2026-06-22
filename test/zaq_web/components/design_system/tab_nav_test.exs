defmodule ZaqWeb.Components.DesignSystem.TabNavTest do
  use ZaqWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias ZaqWeb.Components.DesignSystem.TabNav

  @tabs [
    %{id: :people, label: "People"},
    %{id: :teams, label: "Teams"}
  ]

  test "tab_nav/1 renders tabs with active styling and phx-value-tab" do
    html =
      render_component(&TabNav.tab_nav/1,
        active_tab: :people,
        tabs: @tabs
      )

    assert html =~ "People"
    assert html =~ "Teams"
    assert html =~ ~s(phx-value-tab="people")
    assert html =~ ~s(phx-value-tab="teams")
    assert html =~ ~s(phx-click="switch_tab")
    assert html =~ "zaq-text-accent"
  end

  test "tab_nav/1 marks inactive tab without accent class on active tab only" do
    html = render_component(&TabNav.tab_nav/1, active_tab: :teams, tabs: @tabs)

    assert html =~ "zaq-text-accent"
    assert html =~ "text-black/40"
  end
end
