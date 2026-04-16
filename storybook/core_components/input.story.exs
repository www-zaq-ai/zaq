defmodule Storybook.CoreComponents.Input do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.CoreComponents.input/1
  def description, do: "Labelled input. Supports text, email, password, select, textarea, checkbox."

  def variations do
    [
      %VariationGroup{
        id: :text_types,
        description: "Text inputs",
        variations: [
          %Variation{
            id: :text,
            description: "Text",
            attributes: %{name: "username", label: "Username", value: "", placeholder: "e.g. jana"}
          },
          %Variation{
            id: :email,
            description: "Email",
            attributes: %{name: "email", type: "email", label: "Email address", value: ""}
          },
          %Variation{
            id: :password,
            description: "Password",
            attributes: %{name: "password", type: "password", label: "Password", value: ""}
          }
        ]
      },
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
          }
        ]
      },
      %VariationGroup{
        id: :select,
        description: "Select",
        variations: [
          %Variation{
            id: :select,
            description: "Select",
            attributes: %{
              name: "role",
              type: "select",
              label: "Role",
              options: [{"Admin", "admin"}, {"User", "user"}, {"Viewer", "viewer"}],
              value: "user"
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
            attributes: %{name: "notify", type: "checkbox", label: "Email notifications", value: false}
          },
          %Variation{
            id: :checkbox_on,
            description: "Checked",
            attributes: %{name: "notify", type: "checkbox", label: "Email notifications", value: true}
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
