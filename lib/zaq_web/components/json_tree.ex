defmodule ZaqWeb.Components.JsonTree do
  @moduledoc "Phoenix component for rendering interactive JSON trees via the JsonTree JS hook."

  use Phoenix.Component

  attr :id, :string, required: true
  attr :data, :any, required: true
  attr :class, :string, default: ""

  def json_tree(assigns) do
    ~H"""
    <div id={@id} phx-hook="JsonTree" data-json={Jason.encode!(@data)} class={@class} />
    """
  end
end
