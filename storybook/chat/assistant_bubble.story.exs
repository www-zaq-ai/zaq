defmodule Storybook.Chat.AssistantBubble do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ChatMessage.assistant_bubble/1

  def imports do
    [
      {ZaqWeb.Components.ChatMessage,
       [
         {:message_info_button, 1},
         {:copy_action_button, 1},
         {:feedback_positive_button, 1},
         {:feedback_negative_button, 1}
       ]}
    ]
  end

  def description,
    do:
      "Left-aligned assistant bubble with confidence and sources (`ZaqWeb.Components.ChatMessage`). " <>
        "Message actions (info, copy, thumbs up/down) match the BO chat transcript."

  @actions_slot_base """
  <:actions>
    <.message_info_button available={true} message_id="story-msg-1" open_event="open_message_info_modal" />
    <.copy_action_button text="The refund policy allows returns within 30 days of purchase with a valid receipt." />
  """

  @actions_slot_close """
  </:actions>
  """

  defp actions_slot(feedback_positive, feedback_negative, counts \\ %{positive: nil, negative: nil}) do
    """
    #{@actions_slot_base}
    <.feedback_positive_button message_id="story-msg-1" feedback={#{inspect(feedback_positive)}} count={#{inspect(counts.positive)}} />
    <.feedback_negative_button message_id="story-msg-1" feedback={#{inspect(feedback_negative)}} count={#{inspect(counts.negative)}} />
    #{@actions_slot_close}
    """
    |> String.trim()
  end

  def variations do
    [
      %Variation{
        id: :channel_history,
        description: "Channel history — Agent on the right with ZAQ icon, name and aligned actions",
        attributes: %{
          content: "The rollout is complete. All teams can now use the new workspace.",
          timestamp: ~N[2026-10-01 10:30:05],
          align: :right,
          author_name: "Support Agent"
        },
        slots: [actions_slot(nil, nil, %{positive: 3, negative: 1})]
      },
      %Variation{
        id: :channel_history_own_vote,
        description: "Aggregate counts beside thumbs; only the viewer's own vote is highlighted",
        attributes: %{
          content: "Three positive reactions, including yours, and one negative reaction.",
          timestamp: ~N[2026-10-01 10:30:05],
          align: :right,
          author_name: "Support Agent"
        },
        slots: [actions_slot(:positive, nil, %{positive: 3, negative: 1})]
      },
      %Variation{
        id: :simple,
        description: "Simple response",
        attributes: %{
          content:
            "The refund policy allows returns within 30 days of purchase with a valid receipt.",
          timestamp: ~N[2024-01-15 10:30:05]
        }
      },
      %Variation{
        id: :with_confidence,
        description: "With confidence score",
        attributes: %{
          content:
            "According to the HR handbook, all new employees complete a 90-day onboarding period.",
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
          content:
            "The Q3 roadmap introduces three AI features: smart search, auto-tagging, and a conversational assistant.",
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
          content:
            "Here are the key teams:\n\n- **Platform** — infrastructure and APIs\n- **Product** — features and roadmap\n- **Design** — UX and design system\n\nEach team has a dedicated Slack channel.",
          timestamp: ~N[2024-01-15 10:34:05],
          confidence: 0.79
        }
      },
      %Variation{
        id: :error_state,
        description: "Error state",
        attributes: %{
          content:
            "I was unable to find relevant information in the knowledge base for this query.",
          timestamp: ~N[2024-01-15 10:35:05],
          is_error: true
        }
      },
      %Variation{
        id: :with_message_actions,
        description: "With transcript message actions (info, copy, feedback)",
        attributes: %{
          content:
            "The refund policy allows returns within 30 days of purchase with a valid receipt.",
          timestamp: ~N[2024-01-15 10:36:05],
          confidence: 0.88
        },
        slots: [actions_slot(nil, nil)]
      },
      %Variation{
        id: :with_message_actions_positive,
        description: "Message actions — thumbs up selected",
        attributes: %{
          content: "Glad this helped. Let me know if you need anything else.",
          timestamp: ~N[2024-01-15 10:37:05],
          confidence: 0.91
        },
        slots: [actions_slot(:positive, nil)]
      },
      %Variation{
        id: :with_message_actions_negative,
        description: "Message actions — thumbs down selected",
        attributes: %{
          content: "Here is a shorter answer that may need refinement.",
          timestamp: ~N[2024-01-15 10:38:05],
          confidence: 0.42
        },
        slots: [actions_slot(nil, :negative)]
      },
      %Variation{
        id: :with_saved_negative_feedback,
        description: "Saved negative feedback note under assistant bubble",
        attributes: %{
          content:
            "The refund policy allows returns within 30 days of purchase with a valid receipt.",
          timestamp: ~N[2024-01-15 10:39:05],
          confidence: 0.42,
          saved_feedback_reasons: "Not factually correct, Missing information in knowledge base",
          saved_feedback_user_comment:
            "The answer skipped the probation-period section from the HR handbook."
        },
        slots: [actions_slot(nil, :negative)]
      }
    ]
  end
end
