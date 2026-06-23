defmodule Storybook.Ingestion.ModalRename do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.ModalRename.modal_rename/1
  def description, do: "Rename file or folder modal."

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default",
        attributes: %{modal_error: nil, modal_name: "old-name.pdf"}
      }
    ]
  end
end
