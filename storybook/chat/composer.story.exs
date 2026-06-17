defmodule Storybook.Chat.Composer do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Chat.Composer.composer/1

  def description,
    do:
      "BO Chat — filter chips, textarea, send, and the **@-source autocomplete** " <>
        "(`filter_suggestions` from `ContentFilter`, not starter chips). " <>
        "Starter question chips live in **`ZaqWeb.Chat.SuggestedPrompts`** — see that story."

  def variations do
    filter = %Zaq.Ingestion.ContentSource{
      connector: "Default",
      source_prefix: "docs/",
      label: "docs",
      type: :folder
    }

    file = %Zaq.Ingestion.ContentSource{
      connector: "Default",
      source_prefix: "docs/README.md",
      label: "README.md",
      type: :file
    }

    folder_pick = %Zaq.Ingestion.ContentSource{
      connector: "Default",
      source_prefix: "docs/src/",
      label: "src",
      type: :folder
    }

    current_folder = %Zaq.Ingestion.ContentSource{
      connector: "Default",
      source_prefix: "docs/",
      label: "docs",
      type: :current_folder
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
        id: :busy_input_disabled,
        description: "Agent busy — textarea and send disabled (`status` in busy set)",
        attributes: %{
          active_filters: [],
          filter_suggestions: [],
          input_value:
            "You can still see this draft, but the field is disabled while the agent runs.",
          status: :thinking
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
      },
      %Variation{
        id: :with_at_source_autocomplete,
        description: "@-source autocomplete panel (`filter_suggestions`)",
        attributes: %{
          active_filters: [],
          filter_suggestions: [current_folder, file, folder_pick],
          input_value: "@doc",
          status: :idle
        }
      }
    ]
  end
end
