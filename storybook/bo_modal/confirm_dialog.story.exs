defmodule Storybook.BoModal.ConfirmDialog do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.BOModal.confirm_dialog/1
  def description, do: "Destructive confirmation dialog. Used before delete operations."

  def variations do
    [
      %Variation{
        id: :delete_user,
        description: "Delete user",
        attributes: %{
          title: "Delete user?",
          message: "This action is permanent and cannot be undone.",
          cancel_event: "cancel_delete",
          confirm_event: "confirm_delete"
        }
      },
      %Variation{
        id: :delete_document,
        description: "Delete document — custom labels",
        attributes: %{
          title: "Remove this document?",
          message: "It will be removed from the knowledge base and all associated chunks will be deleted.",
          cancel_event: "cancel_delete",
          confirm_event: "confirm_delete",
          confirm_label: "Remove",
          cancel_label: "Keep it",
          max_width_class: "max-w-md"
        }
      }
    ]
  end
end
