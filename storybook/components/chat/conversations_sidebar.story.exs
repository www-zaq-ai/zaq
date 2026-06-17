defmodule Storybook.Components.Chat.ConversationsSidebar do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Chat.ConversationsSidebar.conversations_sidebar/1

  def description, do: "BO Chat — conversation list and new-chat control."

  def variations do
    now = ~U[2025-06-01 12:00:00Z]

    convs = [
      %{id: "c1", title: "Quarterly planning", channel_type: "bo", inserted_at: now},
      %{id: "c2", title: "(untitled)", channel_type: "bo", inserted_at: now}
    ]

    [
      %Variation{
        id: :empty,
        description: "No conversations",
        attributes: %{
          conversations: [],
          current_conversation_id: nil
        }
      },
      %Variation{
        id: :with_history,
        description: "List with selection",
        attributes: %{
          conversations: convs,
          current_conversation_id: "c1"
        }
      }
    ]
  end
end
