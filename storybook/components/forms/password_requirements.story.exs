defmodule Storybook.Components.Forms.PasswordRequirements do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.PasswordPolicyComponents.password_requirements/1

  def description,
    do:
      "Inline password-strength requirement checklist with live pass/fail indicators. Place below a secret_input field."

  def variations do
    [
      %VariationGroup{
        id: :states,
        description: "Validation states",
        variations: [
          %Variation{
            id: :empty,
            description: "No password entered",
            attributes: %{
              requirements: [
                %{id: "length", label: "At least 8 characters", met?: false},
                %{id: "uppercase", label: "One uppercase letter", met?: false},
                %{id: "number", label: "One number", met?: false},
                %{id: "special", label: "One special character", met?: false}
              ]
            }
          },
          %Variation{
            id: :partial,
            description: "Partial requirements met",
            attributes: %{
              requirements: [
                %{id: "length", label: "At least 8 characters", met?: false},
                %{id: "uppercase", label: "One uppercase letter", met?: true},
                %{id: "number", label: "One number", met?: true},
                %{id: "special", label: "One special character", met?: false}
              ]
            }
          },
          %Variation{
            id: :all_met,
            description: "All requirements met",
            attributes: %{
              requirements: [
                %{id: "length", label: "At least 8 characters", met?: true},
                %{id: "uppercase", label: "One uppercase letter", met?: true},
                %{id: "number", label: "One number", met?: true},
                %{id: "special", label: "One special character", met?: true}
              ]
            }
          }
        ]
      }
    ]
  end
end
