defmodule Storybook.History.HistoryBrowser do
  use PhoenixStorybook.Story, :component
  alias ZaqWeb.Components.DesignSystem.HistoryBrowser
  def container, do: :iframe
  def function, do: &HistoryBrowser.history_browser/1

  def variations do
    [
      %Variation{
        id: :bo,
        attributes: %{
          conversations: [],
          conversation_count: 0,
          is_admin: true,
          filter_scope: "all"
        }
      },
      %Variation{
        id: :people,
        attributes: %{
          conversations: [],
          conversation_count: 0,
          selectable: false,
          actions: false,
          status: "all",
          page: 1,
          status_options: [{"All", "all"}, {"Active", "active"}, {"Archived", "archived"}]
        }
      }
    ]
  end
end
