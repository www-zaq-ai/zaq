defmodule Storybook.Ingestion.ModalDelete do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.ModalDelete.modal_delete/1
  def description, do: "Delete single item confirmation modal."

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default",
        attributes: %{modal_error: nil, modal_name: "report.pdf"}
      }
    ]
  end
end
