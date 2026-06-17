defmodule Storybook.Components.Chat.Transcript do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Chat.Transcript.transcript/1

  def description, do: "BO Chat — transcript area, bubbles, and thinking indicator."

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
      }
    ]
  end
end
