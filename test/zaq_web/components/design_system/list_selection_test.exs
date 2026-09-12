defmodule ZaqWeb.Components.DesignSystem.ListSelectionTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest
  alias ZaqWeb.Components.DesignSystem.ListSelection
  alias ZaqWeb.Helpers.Selection

  test "page checkbox exposes none, mixed and checked states with an accessible label" do
    for {ids, aria} <- [{[], "false"}, {[1], "mixed"}, {[1, 2], "true"}] do
      selection = Selection.toggle_page(Selection.new(%{}), ids)
      html = render_component(&ListSelection.list_selection/1, assigns(selection))
      assert html =~ ~s(aria-checked="#{aria}")
      assert html =~ "Select current page"
      assert html =~ "data-indeterminate=\"#{aria == "mixed"}\""
      assert html =~ "Select all 40 matching results" == (aria == "true")
    end
  end

  test "empty lists disable page selection; all matching exposes exclusions and clear" do
    html =
      render_component(&ListSelection.list_selection/1, %{
        assigns(Selection.new(%{}))
        | page_ids: [],
          total_count: 0
      })

    assert html =~ "disabled"
    refute html =~ "Clear selection"
    selection = Selection.new(%{}) |> Selection.all_matching() |> Selection.toggle(1)
    html = render_component(&ListSelection.list_selection/1, assigns(selection))
    assert html =~ "39 selected"
    assert html =~ "All matching results"
    assert html =~ "1 excluded"
    assert html =~ "Clear selection"
    refute html =~ "Select all 40"
  end

  defp assigns(selection) do
    %{
      id: "selection",
      selection: selection,
      page_ids: [1, 2],
      total_count: 40,
      page_event: "page",
      all_event: "all",
      clear_event: "clear"
    }
  end
end
