defmodule Storybook.Components.ChatMessage.CopyActionButton do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.ChatMessage.copy_action_button/1

  def description,
    do:
      "Copy-to-clipboard control for message text. Page layout for BO chat lives under Components → Chat (`ZaqWeb.Chat`)."

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
