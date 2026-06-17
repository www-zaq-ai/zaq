defmodule Storybook.Chat.SuggestedPrompts do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Chat.SuggestedPrompts.suggested_prompts/1

  def description, do: "BO Chat — starter question chips (`ZaqWeb.Chat`)."

  def variations do
    [
      %Variation{
        id: :default,
        description: "Sample prompts",
        attributes: %{
          suggested_questions: [
            "What is ZAQ and what does it do?",
            "Which integrations does ZAQ support?"
          ]
        }
      }
    ]
  end
end
