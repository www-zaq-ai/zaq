defmodule Storybook.Ingestion.ModalMove do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.ModalMove

  def description, do: "Move ingestion items to another folder (breadcrumb + folder list)."

  def render(assigns) do
    assigns =
      assigns
      |> assign(:modal_error, nil)
      |> assign(:modal_name, "quarterly-report.pdf")
      |> assign(:move_current_dir, "docs")
      |> assign(:move_breadcrumbs, [%{name: "docs", path: "docs"}])
      |> assign(:move_folders, [%{name: "archive"}, %{name: "drafts"}])

    ~H"""
    <div style="padding: var(--zaq-scale-32);">
      <.modal_move
        modal_error={@modal_error}
        modal_name={@modal_name}
        move_current_dir={@move_current_dir}
        move_breadcrumbs={@move_breadcrumbs}
        move_folders={@move_folders}
      />
    </div>
    """
  end
end
