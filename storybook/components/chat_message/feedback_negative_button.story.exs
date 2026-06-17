defmodule Storybook.Components.ChatMessage.FeedbackNegativeButton do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ChatMessage.feedback_negative_button/1

  def description,
    do:
      "Thumbs-down on assistant messages. Page layout for BO chat lives under Components → Chat (`ZaqWeb.Chat`)."

  def variations do
    [
      %Variation{
        id: :unrated,
        description: "Not yet rated",
        attributes: %{message_id: "msg-003", feedback: nil}
      },
      %Variation{
        id: :negative,
        description: "Rated not helpful",
        attributes: %{message_id: "msg-004", feedback: :negative}
      }
    ]
  end
end
