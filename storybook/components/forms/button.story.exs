defmodule Storybook.Components.Forms.Button do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.CoreComponents.button/1

  def description,
    do: "Primary action button. Renders as `<button>` or `<.link>` depending on props."

  def variations do
    [
      %VariationGroup{
        id: :variants,
        description: "Button variants",
        variations: [
          %Variation{
            id: :soft,
            description: "Soft (default)",
            slots: ["Save changes"]
          },
          %Variation{
            id: :primary,
            description: "Primary",
            attributes: %{variant: "primary"},
            slots: ["Confirm"]
          }
        ]
      },
      %VariationGroup{
        id: :states,
        description: "States",
        variations: [
          %Variation{
            id: :disabled,
            description: "Disabled",
            attributes: %{disabled: true},
            slots: ["Unavailable"]
          }
        ]
      },
      %VariationGroup{
        id: :as_link,
        description: "As navigation link",
        variations: [
          %Variation{
            id: :navigate,
            description: "navigate=",
            attributes: %{navigate: "/bo/dashboard"},
            slots: ["Go to dashboard"]
          }
        ]
      },
      %VariationGroup{
        id: :loading,
        description: "Loading action button",
        variations: [
          %Variation{
            id: :idle,
            description: "Idle state",
            attributes: %{},
            slots: ["Run diagnostics"]
          },
          %Variation{
            id: :loading,
            description: "Loading state — use loading_action_button/1 for async actions",
            attributes: %{disabled: true},
            slots: ["Running…"]
          }
        ]
      }
    ]
  end
end
