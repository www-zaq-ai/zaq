defmodule Storybook.Chat.CopyActionButton do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ChatMessage.copy_action_button/1

  def description,
    do: "Copy-to-clipboard for message text (`ZaqWeb.Components.ChatMessage`)."

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default",
        attributes: %{
          text:
            "The refund policy allows returns within 30 days of purchase with a valid receipt."
        }
      }
    ]
  end
end
