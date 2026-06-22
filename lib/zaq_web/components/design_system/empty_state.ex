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
    <div class={["py-16 text-center", @class]}>
      <p class="font-mono text-sm text-black/30">{@title}</p>
      <p :if={@hint} class="font-mono text-[0.7rem] text-black/20 mt-1">{@hint}</p>
    </div>
    """
  end
end
