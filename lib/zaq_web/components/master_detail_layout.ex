defmodule ZaqWeb.Components.MasterDetailLayout do
  @moduledoc """
  Reusable master/detail layout component for BO pages.

  Renders a master slot and, when `show_detail` is true, a detail slot alongside it.
  """

  use Phoenix.Component

  attr :show_detail, :boolean, default: false
  attr :container_class, :string, default: "flex gap-6 min-h-[70vh]"
  attr :master_when_detail_class, :string, default: "w-1/3 flex-shrink-0"
  attr :master_when_no_detail_class, :string, default: "w-full"
  attr :master_id, :string, default: nil
  attr :detail_id, :string, default: nil

  slot :master, required: true
  slot :detail

  @doc "Renders the responsive master/detail container and slots."
  def master_detail(assigns) do
    ~H"""
    <div class={@container_class}>
      <div
        id={@master_id}
        class={if @show_detail, do: @master_when_detail_class, else: @master_when_no_detail_class}
      >
        {render_slot(@master)}
      </div>

      <div :if={@show_detail} id={@detail_id} class="w-2/3 min-w-0">
        {render_slot(@detail)}
      </div>
    </div>
    """
  end
end
