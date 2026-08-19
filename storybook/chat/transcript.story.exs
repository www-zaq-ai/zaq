defmodule Storybook.Chat.Transcript do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Chat.Transcript.transcript/1

  def description,
    do: "BO Chat — transcript area, bubbles, and thinking indicator (`ZaqWeb.Chat`)."

  def variations do
    ts = ~U[2025-06-01 12:00:00Z]

    welcome = %{
      id: "w1",
      role: :bot,
      body: "Welcome to ZAQ Chat! Ask me anything about your knowledge base.",
      timestamp: ts,
      confidence: nil,
      error: false,
      feedback: nil,
      welcome: true,
      message_info: %{}
    }

    user_msg = %{
      id: "u1",
      role: :user,
      body: "What is ZAQ?",
      timestamp: ts,
      filters: []
    }

    user_attachment = %{
      id: "u2",
      role: :user,
      body: "Please review this image.",
      timestamp: ts,
      filters: [],
      attachments: [
        %{
          "id" => "file-1",
          "name" => "storefront.png",
          "mime_type" => "image/png",
          "size" => 82_944
        }
      ]
    }

    assistant_with_actions = %{
      id: "a1",
      role: :bot,
      body:
        "The refund policy allows returns within 30 days of purchase with a valid receipt. I can also summarize related HR policies if you need them.",
      timestamp: ts,
      confidence: 0.88,
      error: false,
      feedback: nil,
      sources: [],
      message_info: %{
        agent: "ZAQ Assistant",
        model: "story-model",
        measurements: %{},
        traces: []
      },
      live: false
    }

    [
      %Variation{
        id: :welcome_only,
        description: "Welcome message only",
        attributes: %{
          messages: [welcome],
          status: :idle,
          status_message: "",
          streaming_response_active: false
        }
      },
      %Variation{
        id: :thinking,
        description: "Thinking / pipeline status",
        attributes: %{
          messages: [welcome, user_msg],
          status: :thinking,
          status_message: "ZAQ is analyzing your question…",
          streaming_response_active: false
        }
      },
      %Variation{
        id: :chat_page_with_assistant_actions,
        description: "Chat page — user + assistant with message actions (as in BO transcript)",
        attributes: %{
          messages: [user_msg, assistant_with_actions],
          status: :idle,
          status_message: "",
          streaming_response_active: false
        }
      },
      %Variation{
        id: :message_with_attachment,
        description: "User message with persisted attachment metadata",
        attributes: %{
          messages: [user_attachment, assistant_with_actions],
          status: :idle,
          status_message: "",
          streaming_response_active: false
        }
      }
    ]
  end
end
