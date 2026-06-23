defmodule Storybook.Components.Forms.Textarea do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.Input.input/1

  def description, do: "Multiline textarea rendered via DesignSystem.Input."

  def variations do
    [
      %VariationGroup{
        id: :multiline,
        description: "Textarea",
        variations: [
          %Variation{
            id: :textarea,
            description: "Textarea",
            attributes: %{
              name: "bio",
              type: "textarea",
              label: "Bio",
              value: "",
              placeholder: "Tell us about yourself…",
              rows: "4"
            }
          },
          %Variation{
            id: :with_error,
            description: "With validation error",
            attributes: %{
              name: "bio",
              type: "textarea",
              label: "Bio",
              value: "Hi",
              errors: ["is too short"]
            }
          }
        ]
      }
    ]
  end
end
