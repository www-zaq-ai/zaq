defmodule Storybook.Components.ListSelection do
  use PhoenixStorybook.Story, :component
  alias ZaqWeb.Helpers.Selection

  def function, do: &ZaqWeb.Components.DesignSystem.ListSelection.list_selection/1
  def description, do: "Parent-owned page-first selection, all filter matches, and exclusions."

  def variations do
    empty = Selection.new(%{})
    page = Selection.toggle_page(empty, [1, 2])
    all = Selection.all_matching(page)

    for {id, selection, ids, total} <- [
          {:empty, empty, [], 0},
          {:none, empty, [1, 2], 40},
          {:partial, Selection.toggle(empty, 1), [1, 2], 40},
          {:page, page, [1, 2], 40},
          {:all_matching, all, [1, 2], 40},
          {:exclusions, Selection.toggle(all, 1), [1, 2], 40}
        ] do
      %Variation{
        id: id,
        attributes: %{
          id: "selection-#{id}",
          selection: selection,
          page_ids: ids,
          total_count: total,
          page_event: "select_page",
          all_event: "select_all",
          clear_event: "clear"
        }
      }
    end
  end
end
