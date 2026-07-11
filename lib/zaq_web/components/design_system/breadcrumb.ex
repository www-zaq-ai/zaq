defmodule ZaqWeb.Components.DesignSystem.Breadcrumb do
  @moduledoc """
  Path breadcrumbs and back control for the BO ingestion file browser.

  **Styles:** universal block in `assets/css/styles.css` — `.zaq-breadcrumb-*`,
  plus shared `.zaq-icon-sm` and `.zaq-link-underline` (not under the ingestion-only section).
  """

  use Phoenix.Component

  attr :breadcrumbs, :list, required: true
  attr :current_dir, :string, required: true

  def breadcrumb(assigns) do
    assigns = assign(assigns, :visible?, breadcrumb_visible?(assigns))

    ~H"""
    <div :if={@visible?} class="zaq-breadcrumb-row zaq-text-body-sm">
      <button
        :if={@current_dir != "."}
        phx-click="go_back"
        class="zaq-breadcrumb-back-btn"
        title="Go back"
        type="button"
      >
        <svg
          class="zaq-icon-sm"
          fill="none"
          stroke="currentColor"
          stroke-width="2.5"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
        </svg>
      </button>
      <button
        phx-click="navigate"
        phx-value-path="."
        class="zaq-link-underline zaq-breadcrumb-crumb-link"
        type="button"
      >
        root
      </button>
      <span :for={crumb <- @breadcrumbs} class="zaq-breadcrumb-trail">
        <span class="zaq-breadcrumb-sep">/</span>
        <button
          phx-click="navigate"
          phx-value-path={crumb.path}
          class="zaq-link-underline zaq-breadcrumb-crumb-link"
          type="button"
        >
          {crumb.name}
        </button>
      </span>
    </div>
    """
  end

  defp breadcrumb_visible?(%{current_dir: ".", breadcrumbs: []}), do: false
  defp breadcrumb_visible?(_), do: true
end
