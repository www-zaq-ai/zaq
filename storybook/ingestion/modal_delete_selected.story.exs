defmodule Storybook.Ingestion.ModalDeleteSelected do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.ModalDeleteSelected

  def description, do: "Bulk delete confirmation for selected ingestion items (BOModal)."

  def render(assigns) do
    assigns = assign(assigns, :selected, MapSet.new(["a", "b", "c"]))

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.modal_delete_selected selected={@selected} />
    </div>
    """
  end
end
