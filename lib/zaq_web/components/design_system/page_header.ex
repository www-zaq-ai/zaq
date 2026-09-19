defmodule ZaqWeb.Components.DesignSystem.PageHeader do
  @moduledoc """
  Shared page-header presentation extracted from BOLayout.
  Callers own branding, consent/context and action destinations. This component
  has no authentication, sidebar, feature loading or provider knowledge.
  """
  use Phoenix.Component

  attr :id, :string, default: nil
  attr :class, :any, default: nil
  attr :identity_class, :any, default: nil
  attr :actions_class, :any, default: nil
  slot :brand
  slot :heading, required: true
  slot :context
  slot :actions

  def page_header(assigns) do
    ~H"""
    <header id={@id} class={["zaq-page-header", @class]}>
      <div class={["zaq-page-header-identity", @identity_class]}>
        <div :if={@brand != []} class="shrink-0">{render_slot(@brand)}</div>
        {render_slot(@heading)}
      </div>
      <div :if={@context != []} class="flex-1 min-w-0">{render_slot(@context)}</div>
      <div :if={@actions != []} class={["zaq-page-header-actions", @actions_class]}>
        {render_slot(@actions)}
      </div>
    </header>
    """
  end

  attr :id, :string, default: "page"
  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :description_class, :any, default: nil
  attr :heading_testid, :string, default: nil
  slot :icon
  slot :tag
  slot :subtitle

  def page_heading(assigns) do
    assigns =
      assign(
        assigns,
        :compact?,
        (is_binary(assigns.description) and assigns.description != "") or
          assigns.subtitle != [] or assigns.tag != []
      )

    ~H"""
    <div class="zaq-layout-inline min-w-0 max-w-2xl">
      {render_slot(@icon)}
      <div id={"#{@id}-heading"} class="min-w-0 flex-1">
        <div class="zaq-layout-inline flex-wrap min-w-0">
          <h1
            id={"#{@id}-title"}
            data-testid={@heading_testid}
            class={[
              "break-words min-w-0",
              if(@compact?, do: "zaq-text-body", else: "zaq-text-body-lg")
            ]}
            style="color: var(--zaq-text-color-body-default);"
          >
            {@title}
          </h1>
          <span :if={@tag != []} id={"#{@id}-tag"} class="shrink-0 flex items-center">{render_slot(
            @tag
          )}</span>
        </div>
        <%= if @subtitle != [] do %>
          <div
            id={"#{@id}-subtitle"}
            class={["zaq-text-body-sm break-words", @description_class]}
            style="color: var(--zaq-text-color-body-tertiary);"
          >
            {render_slot(@subtitle)}
          </div>
        <% else %>
          <p
            :if={@description}
            id={"#{@id}-subtitle"}
            class={["zaq-text-body-sm break-words", @description_class]}
            style="color: var(--zaq-text-color-body-tertiary);"
          >
            {@description}
          </p>
        <% end %>
      </div>
    </div>
    """
  end
end
