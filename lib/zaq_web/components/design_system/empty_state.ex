defmodule ZaqWeb.Components.DesignSystem.EmptyState do
  @moduledoc """
  Centered empty-list message for BO master panels.

  Primary line plus optional hint (e.g. “Click New Person to add one.”).
  """

  use Phoenix.Component

  attr :title, :string, required: true
  attr :hint, :string, default: nil
  attr :class, :string, default: ""

  def empty_state(assigns) do
    ~H"""
    <div class={["zaq-empty-state", @class]}>
      <div class="zaq-layout-stack-tight">
        <p class="zaq-text-body" style="color: var(--zaq-text-color-body-secondary)">
          {@title}
        </p>
        <p
          :if={@hint}
          class="zaq-text-body-sm"
          style="color: var(--zaq-text-color-body-tertiary)"
        >
          {@hint}
        </p>
      </div>
    </div>
    """
  end
end
