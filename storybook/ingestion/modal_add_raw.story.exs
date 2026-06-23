defmodule Storybook.Ingestion.ModalAddRaw do
  use PhoenixStorybook.Story, :component

  def function, do: &ZaqWeb.Components.DesignSystem.ModalAddRaw.modal_add_raw/1
  def description, do: "Add raw Markdown file modal."

  def variations do
    [
      %Variation{
        id: :default,
        description: "Default",
        attributes: %{modal_error: nil, modal_name: "my-note", current_dir: "docs"}
      }
    ]
  end
end
