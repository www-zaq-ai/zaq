defmodule Storybook.Components.Chat.FeedbackModal do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Chat.Modals.feedback_modal/1

  def description, do: "BO Chat — negative feedback reasons and comment."

  def variations do
    [
      %Variation{
        id: :hidden,
        description: "Closed",
        attributes: %{
          show_feedback_modal: false,
          feedback_reasons: [],
          feedback_comment: ""
        }
      },
      %Variation{
        id: :open,
        description: "Open with one reason selected",
        attributes: %{
          show_feedback_modal: true,
          feedback_reasons: ["Not factually correct"],
          feedback_comment: "Details here."
        }
      }
    ]
  end
end
