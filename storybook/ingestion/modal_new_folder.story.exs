defmodule Storybook.Ingestion.ModalNewFolder do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.ModalNewFolder.modal_new_folder/1
  def description, do: "Create new folder modal."

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default",
        attributes: %{modal_error: nil, modal_name: "new-folder"}
      }
    ]
  end
end
