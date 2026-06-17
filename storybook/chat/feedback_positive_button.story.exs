defmodule Storybook.Chat.FeedbackPositiveButton do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ChatMessage.feedback_positive_button/1

  def description,
    do: "Thumbs-up on assistant messages (`ZaqWeb.Components.ChatMessage`)."

  def variations do
    [
      %Variation{
        id: :unrated,
        description: "Not yet rated",
        attributes: %{message_id: "msg-001", feedback: nil}
      },
      %Variation{
        id: :positive,
        description: "Rated helpful",
        attributes: %{message_id: "msg-002", feedback: :positive}
      }
    ]
  end
end
