defmodule Storybook.CoreComponents.Header do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.CoreComponents.header/1
  def description, do: "Page-level header with optional subtitle and actions slot."

  def variations do
    [
      %Variation{
        id: :simple,
        description: "Title only",
        slots: ["Knowledge Base"]
      },
      %Variation{
        id: :with_subtitle,
        description: "Title + subtitle",
        slots: [
          "Ingestion",
          "<:subtitle>Manage and monitor document processing.</:subtitle>"
        ]
      },
      %Variation{
        id: :with_actions,
        description: "Title + subtitle + action",
        slots: [
          "Users",
          "<:subtitle>Manage team members and their access.</:subtitle>",
          "<:actions><button class=\"btn btn-primary\">New user</button></:actions>"
        ]
      }
    ]
  end
end
