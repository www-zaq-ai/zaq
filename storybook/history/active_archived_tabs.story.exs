defmodule Storybook.History.ActiveArchivedTabs do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.History.ActiveArchivedTabs.active_archived_tabs/1

  def description,
    do: "BO History — Active / Archived route tabs (`ZaqWeb.History.ActiveArchivedTabs`)."

  def variations do
    [
      %Variation{
        id: :active_selected,
        description: "Active route (default index)",
        attributes: %{live_action: :index}
      },
      %Variation{
        id: :archived_selected,
        description: "Archived route",
        attributes: %{live_action: :archived}
      }
    ]
  end
end
