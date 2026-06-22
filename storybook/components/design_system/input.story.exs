defmodule Storybook.Components.DesignSystem.Input do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.Input.input/1

  def description,
    do: "Labelled form input with validation errors — text, select, textarea, and checkbox."

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
        id: :select_textarea,
        description: "Select and textarea",
        variations: [
          %Variation{
            id: :select,
            description: "Select",
            attributes: %{
              name: "role",
              type: "select",
              label: "Role",
              value: "admin",
              prompt: "Choose one",
              options: [{"Admin", "admin"}, {"User", "user"}]
            }
          },
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
        id: :checkbox,
        description: "Checkbox",
        variations: [
          %Variation{
            id: :checkbox_off,
            description: "Unchecked",
            attributes: %{
              name: "notify",
              type: "checkbox",
              label: "Email notifications",
              value: false
            }
          },
          %Variation{
            id: :checkbox_on,
            description: "Checked",
            attributes: %{
              name: "notify",
              type: "checkbox",
              label: "Email notifications",
              value: true
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
              name: "email",
              type: "email",
              label: "Email address",
              value: "not-an-email",
              errors: ["is not a valid email address"]
            }
          }
        ]
      }
    ]
  end
end
