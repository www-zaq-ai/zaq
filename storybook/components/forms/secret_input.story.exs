defmodule Storybook.Components.Forms.SecretInput do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.SecretInput.secret_input/1

  def description,
    do:
      "Password or token field with show/hide toggle and optional field errors. Uses the same .zaq-control-text shell as Input."

  def variations do
    [
      %VariationGroup{
        id: :default,
        description: "Secret input",
        variations: [
          %Variation{
            id: :empty,
            description: "Empty",
            attributes: %{
              id: "api-key",
              name: "api_key",
              label: "API key",
              value: "",
              placeholder: "sk-…"
            }
          },
          %Variation{
            id: :filled,
            description: "Filled",
            attributes: %{
              id: "api-key-filled",
              name: "api_key",
              label: "API key",
              value: "sk-live-xxxxxxxxxxxx"
            }
          }
        ]
      },
      %VariationGroup{
        id: :errors,
        description: "With validation errors",
        variations: [
          %Variation{
            id: :with_error,
            description: "Field error",
            attributes: %{
              id: "token",
              name: "token",
              label: "Token",
              value: "",
              errors: ["can't be blank"]
            }
          }
        ]
      }
    ]
  end
end
