defmodule Storybook.History.BulkSelectionBar do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.History.BulkSelectionBar.bulk_selection_bar/1

  def description,
    do:
      "BO History — bulk Archive / Delete when rows are selected (`ZaqWeb.History.BulkSelectionBar`)."

  def variations do
    [
      %Variation{
        id: :none_selected,
        description: "Nothing selected (bar hidden)",
        attributes: %{selected_count: 0, live_action: :index}
      },
      %Variation{
        id: :active_list,
        description: "Two selected on active list — Archive + Delete",
        attributes: %{selected_count: 2, live_action: :index}
      },
      %Variation{
        id: :archived_list,
        description: "Archived list — Delete only (no bulk Archive)",
        attributes: %{selected_count: 1, live_action: :archived}
      }
    ]
  end
end
