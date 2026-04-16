defmodule Storybook.ChatMessage.UserBubble do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ChatMessage.user_bubble/1
  def description, do: "Right-aligned user message bubble in the ZAQ chat interface."

  def variations do
    [
      %Variation{
        id: :short,
        description: "Short message",
        attributes: %{
          content: "What is our refund policy?",
          timestamp: ~N[2024-01-15 10:30:00]
        }
      },
      %Variation{
        id: :long,
        description: "Longer message",
        attributes: %{
          content: "Can you summarise the key changes in the Q3 product roadmap and tell me which teams are responsible for the new AI features?",
          timestamp: ~N[2024-01-15 10:31:00]
        }
      },
      %Variation{
        id: :multiline,
        description: "Multi-line message",
        attributes: %{
          content: "I have two questions:\n1. Where is the onboarding checklist?\n2. Who should I contact for IT access?",
          timestamp: ~N[2024-01-15 10:32:00]
        }
      }
    ]
  end
end
