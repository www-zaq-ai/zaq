defmodule ZaqWeb.Select do
  @moduledoc "Reusable native select component styled with the zaq-control-select token system."

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  attr :id, :string, default: nil
  attr :name, :string, required: true
  attr :label, :string, default: nil
  attr :value, :any, default: nil
  attr :options, :list, required: true
  attr :prompt, :string, default: nil
  attr :multiple, :boolean, default: false
  attr :errors, :list, default: []
  attr :class, :string, default: nil
  attr :rest, :global, include: ~w(disabled form autofocus)

  def select(assigns) do
    ~H"""
    <div class="zaq-field-row-block">
      <label
        :if={@label}
        class="zaq-field-label-uppercase"
        for={@id || @name}
      >
        {@label}
      </label>
      <select
        id={@id || @name}
        name={@name}
        class={["zaq-control-select w-full", @class]}
        multiple={@multiple}
        {@rest}
      >
        <option :if={@prompt} value="">{@prompt}</option>
        {Phoenix.HTML.Form.options_for_select(@options, @value)}
      </select>
      <p :for={msg <- @errors} class="mt-1.5 flex gap-2 items-center text-sm text-error">
        <.icon name="hero-exclamation-circle" class="size-5" />
        {msg}
      </p>
    </div>
    """
  end
end
