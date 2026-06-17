defmodule Storybook.Chat.Composer do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Chat.Composer.composer/1

  def description, do: "BO Chat — filter chips, textarea, and send button (`ZaqWeb.Chat`)."

  def variations do
    filter = %Zaq.Ingestion.ContentSource{
      connector: "Default",
      source_prefix: "docs/",
      label: "docs",
      type: :folder
    }

    [
      %Variation{
        id: :idle_empty,
        description: "Idle, no filters",
        attributes: %{
          active_filters: [],
          filter_suggestions: [],
          input_value: "",
          status: :idle
        }
      },
      %Variation{
        id: :with_draft,
        description: "Draft message",
        attributes: %{
          active_filters: [],
          filter_suggestions: [],
          input_value: "Hello from Storybook",
          status: :idle
        }
      },
      %Variation{
        id: :with_filter,
        description: "Active content filter chip",
        attributes: %{
          active_filters: [filter],
          filter_suggestions: [],
          input_value: "Filtered question",
          status: :idle
        }
      }
    ]
  end
end
