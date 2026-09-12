defmodule ZaqWeb.Components.DesignSystem.ListSelectionTest do
  use ExUnit.Case, async: true
  use Phoenix.Component
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

  test "checkbox, recap, clear and actions form wrapping inline clusters in reading order" do
    selection = Selection.toggle_page(Selection.new(%{}), [1, 2])
    html = render_component(&selection_with_actions/1, assigns(selection))
    document = LazyHTML.from_fragment(html)

    assert Enum.count(
             LazyHTML.query(
               document,
               "#selection.zaq-layout-inline.flex-wrap > .zaq-field-row-block"
             )
           ) == 1

    assert Enum.count(
             LazyHTML.query(
               document,
               "#selection > [aria-live=polite].zaq-layout-inline.flex-wrap"
             )
           ) == 1

    assert Enum.count(
             LazyHTML.query(
               document,
               "[aria-live] > .zaq-layout-inline.flex-wrap > span + #selection-clear"
             )
           ) == 1

    assert LazyHTML.query(document, "[aria-live] button") |> LazyHTML.attribute("id") ==
             ["selection-clear", "selection-all", "bulk-action"]

    assert html =~ "2 selected"
    assert html =~ ~s(phx-click="page")
    assert html =~ ~s(phx-click="all")
    assert html =~ ~s(phx-click="clear")
  end

  test "all matching recap stays beside clear, including when every result is excluded" do
    all = Selection.all_matching(Selection.new(%{}))

    for {selection, count, excluded} <- [
          {all, 2, 0},
          {Selection.toggle(all, 1), 1, 1},
          {Selection.toggle_page(all, [1, 2]), 0, 2}
        ] do
      html =
        render_component(&selection_with_actions/1, %{assigns(selection) | total_count: 2})

      document = LazyHTML.from_fragment(html)
      assert html =~ "#{count} selected"

      recap = LazyHTML.query(document, "[aria-live] > div > span:nth-child(2)")
      assert LazyHTML.text(recap) =~ "#{excluded} excluded."

      assert Enum.count(
               LazyHTML.query(
                 document,
                 "[aria-live] > div > span:nth-child(2) + #selection-clear"
               )
             ) == 1

      assert Enum.empty?(LazyHTML.query(document, "#bulk-action")) == (count == 0)
      refute html =~ "Select all 2"
    end
  end

  test "no selection hides recap, clear and domain actions; partial selection hides select all" do
    for {selection, selected?} <- [
          {Selection.new(%{}), false},
          {Selection.toggle(Selection.new(%{}), 1), true}
        ] do
      html = render_component(&selection_with_actions/1, assigns(selection))
      assert html =~ "Clear selection" == selected?
      assert html =~ "Bulk action" == selected?
      refute html =~ "Select all 40"
    end
  end

  defp selection_with_actions(assigns) do
    ~H"""
    <ListSelection.list_selection {assigns}>
      <:actions><button id="bulk-action">Bulk action</button></:actions>
    </ListSelection.list_selection>
    """
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
