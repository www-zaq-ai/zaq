defmodule Storybook.Components.Forms.Select do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Select.select/1

  def description, do: "Styled native select using the zaq-control-select token system."

  def variations do
    [
      %VariationGroup{
        id: :select,
        description: "Select",
        variations: [
          %Variation{
            id: :default,
            description: "Default",
            attributes: %{
              name: "role",
              label: "Role",
              options: [{"Admin", "admin"}, {"User", "user"}, {"Viewer", "viewer"}],
              value: "user"
            }
          },
          %Variation{
            id: :with_prompt,
            description: "With prompt",
            attributes: %{
              name: "role",
              label: "Role",
              prompt: "Choose a role…",
              options: [{"Admin", "admin"}, {"User", "user"}, {"Viewer", "viewer"}],
              value: nil
            }
          },
          %Variation{
            id: :with_error,
            description: "With validation error",
            attributes: %{
              name: "role",
              label: "Role",
              options: [{"Admin", "admin"}, {"User", "user"}],
              value: nil,
              errors: ["can't be blank"]
            }
          }
        ]
      }
    ]
  end
end
