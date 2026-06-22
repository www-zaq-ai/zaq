defmodule ZaqWeb.Select do
  @moduledoc "Reusable select component — styled dropdown via SearchableSelect with search disabled."

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]
  import ZaqWeb.Components.SearchableSelect, only: [searchable_select: 1]

  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :prompt, :string, default: nil
  attr :errors, :list, default: []
  attr :class, :string, default: nil

  def select(assigns) do
    ~H"""
    <div class={["zaq-field-row-block", @class]}>
      <.searchable_select
        id={@id || @name}
        name={@name}
        label={@label}
        label_position="block"
        value={@value}
        options={@options}
        empty_label={@prompt || "Select…"}
        searchable={false}
      />
      <p :for={msg <- @errors} class="mt-1.5 flex gap-2 items-center text-sm text-error">
        <.icon name="hero-exclamation-circle" class="size-5" />
        {msg}
      </p>
    </div>
    """
  end
end
