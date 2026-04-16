defmodule Storybook.CoreComponents.Table do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.CoreComponents.table/1
  def description, do: "Zebra-striped data table with optional row-click and actions column."

  def variations do
    [
      %Variation{
        id: :basic,
        description: "Basic table",
        attributes: %{
          id: "story-users-table",
          rows: [
            %{id: 1, name: "Jana Abiakar", role: "Admin", status: "Active"},
            %{id: 2, name: "Alex Martin", role: "User", status: "Active"},
            %{id: 3, name: "Sam Lee", role: "Viewer", status: "Inactive"}
          ]
        },
        slots: [
          "<:col :let={row} label=\"Name\">{row.name}</:col>",
          "<:col :let={row} label=\"Role\">{row.role}</:col>",
          "<:col :let={row} label=\"Status\">{row.status}</:col>"
        ]
      },
      %Variation{
        id: :with_actions,
        description: "With actions column",
        attributes: %{
          id: "story-users-table-actions",
          rows: [
            %{id: 1, name: "Jana Abiakar", role: "Admin"},
            %{id: 2, name: "Alex Martin", role: "User"}
          ]
        },
        slots: [
          "<:col :let={row} label=\"Name\">{row.name}</:col>",
          "<:col :let={row} label=\"Role\">{row.role}</:col>",
          "<:action :let={_row}><a class=\"link link-primary text-sm\">Edit</a></:action>"
        ]
      }
    ]
  end
end
