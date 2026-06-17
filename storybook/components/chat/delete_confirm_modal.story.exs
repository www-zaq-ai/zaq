defmodule Storybook.Components.Chat.DeleteConfirmModal do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Chat.Modals.delete_confirm_modal/1

  def description, do: "BO Chat — delete conversation confirmation."

  def variations do
    [
      %Variation{
        id: :hidden,
        description: "Closed",
        attributes: %{show_delete_confirm: false}
      },
      %Variation{
        id: :visible,
        description: "Open",
        attributes: %{show_delete_confirm: true}
      }
    ]
  end
end
