defmodule Storybook.Components.Forms.Input do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.Input.input/1

  def description,
    do:
      "Labelled form input (ZAQ tokens): text-like types, textarea, and validation errors. Boolean fields: Checkbox. Dropdowns: Select / SearchableSelect. Sensitive fields: SecretInput."

  def variations do
    [
      %VariationGroup{
        id: :text_types,
        description: "Text inputs",
        variations: [
          %Variation{
            id: :text,
            description: "Text",
            attributes: %{
              name: "username",
              label: "Username",
              value: "",
              placeholder: "e.g. jana"
            }
          },
          %Variation{
            id: :email,
            description: "Email",
            attributes: %{name: "email", type: "email", label: "Email address", value: ""}
          },
          %Variation{
            id: :number,
            description: "Number",
            attributes: %{
              name: "max_iterations",
              type: "number",
              label: "Max iterations",
              value: "",
              placeholder: "Default: 10"
            }
          }
        ]
      },
      %VariationGroup{
        id: :textarea,
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
          }
        ]
      },
      %VariationGroup{
        id: :errors,
        description: "With validation errors",
        variations: [
          %Variation{
            id: :with_error,
            description: "Field error (email)",
            attributes: %{
              name: "email",
              type: "email",
              label: "Email address",
              value: "not-an-email",
              errors: ["is not a valid email address"]
            }
          },
          %Variation{
            id: :textarea_with_error,
            description: "Field error (textarea)",
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
