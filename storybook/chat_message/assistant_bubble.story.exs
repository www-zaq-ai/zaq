defmodule Storybook.ChatMessage.AssistantBubble do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ChatMessage.assistant_bubble/1
  def description, do: "Left-aligned ZAQ assistant response bubble with confidence bar and source chips."

  def variations do
    [
      %Variation{
        id: :simple,
        description: "Simple response",
        attributes: %{
          content: "The refund policy allows returns within 30 days of purchase with a valid receipt.",
          timestamp: ~N[2024-01-15 10:30:05]
        }
      },
      %Variation{
        id: :with_confidence,
        description: "With confidence score",
        attributes: %{
          content: "According to the HR handbook, all new employees complete a 90-day onboarding period.",
          timestamp: ~N[2024-01-15 10:31:05],
          confidence: 0.87
        }
      },
      %Variation{
        id: :low_confidence,
        description: "Low confidence",
        attributes: %{
          content: "I found some partial information but the documentation may be incomplete.",
          timestamp: ~N[2024-01-15 10:32:05],
          confidence: 0.34
        }
      },
      %Variation{
        id: :with_sources,
        description: "With source chips",
        attributes: %{
          content: "The Q3 roadmap introduces three AI features: smart search, auto-tagging, and a conversational assistant.",
          timestamp: ~N[2024-01-15 10:33:05],
          confidence: 0.92,
          sources: [
            %{"index" => 1, "path" => "documents/q3-roadmap.pdf"},
            %{"index" => 2, "path" => "documents/ai-strategy-2024.pdf"}
          ]
        }
      },
      %Variation{
        id: :markdown,
        description: "Markdown content",
        attributes: %{
          content: "Here are the key teams:\n\n- **Platform** — infrastructure and APIs\n- **Product** — features and roadmap\n- **Design** — UX and design system\n\nEach team has a dedicated Slack channel.",
          timestamp: ~N[2024-01-15 10:34:05],
          confidence: 0.79
        }
      },
      %Variation{
        id: :error_state,
        description: "Error state",
        attributes: %{
          content: "I was unable to find relevant information in the knowledge base for this query.",
          timestamp: ~N[2024-01-15 10:35:05],
          is_error: true
        }
      }
    ]
  end
end
