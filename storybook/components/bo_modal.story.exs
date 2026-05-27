defmodule Storybook.Components.BoModal do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.BOModal.confirm_dialog/1
  def description, do: "Confirmation dialog for destructive or important actions."

  def variations do
    [
      %VariationGroup{
        id: :variants,
        description: "Dialog variants",
        variations: [
          %Variation{
            id: :default,
            description: "Default confirm",
            attributes: %{
              title: "Delete document",
              message: "This action cannot be undone. The document will be permanently deleted.",
              confirm_label: "Delete",
              cancel_label: "Cancel",
              cancel_event: "close_modal"
            }
          },
          %Variation{
            id: :custom_labels,
            description: "Custom labels",
            attributes: %{
              title: "Archive workspace",
              message: "Archiving will hide this workspace from all members. You can restore it later.",
              confirm_label: "Archive",
              cancel_label: "Keep active",
              cancel_event: "close_modal"
            }
          },
          %Variation{
            id: :narrow,
            description: "Narrow width",
            attributes: %{
              title: "Remove member",
              message: "Jana Abiakar will lose access to this workspace.",
              confirm_label: "Remove",
              cancel_event: "close_modal",
              max_width_class: "max-w-sm"
            }
          }
        ]
      }
    ]
  end
end
