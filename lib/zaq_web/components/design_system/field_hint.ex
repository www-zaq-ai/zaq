defmodule ZaqWeb.Components.DesignSystem.FieldHint do
  @moduledoc """
  Validation errors and optional hints below form controls.

  Hints use `:info`, `:success`, or `:error` tones. When `errors` is non-empty, hints are hidden.
  """

  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1]

  attr :errors, :list, default: []
  attr :hint, :string, default: nil
  attr :hint_tone, :atom, default: :info, values: [:info, :success, :error]
  attr :hint_id, :string, default: nil
  attr :error_id, :string, default: nil

  def field_messages(assigns) do
    ~H"""
    <.field_error
      :for={{msg, index} <- Enum.with_index(@errors)}
      id={if @error_id, do: if(index == 0, do: @error_id, else: "#{@error_id}-#{index}")}
    >
      {msg}
    </.field_error>
    <p
      :if={@errors == [] && @hint}
      id={@hint_id}
      class={[
        "zaq-field-hint zaq-text-body-sm",
        hint_tone_class(@hint_tone)
      ]}
    >
      <.icon name={hint_icon(@hint_tone)} class="zaq-icon-sm" />
      {@hint}
    </p>
    """
  end

  attr :id, :string, default: nil
  slot :inner_block, required: true

  defp field_error(assigns) do
    ~H"""
    <p id={@id} class="zaq-field-error zaq-text-body-sm">
      <.icon name="hero-exclamation-circle" class="zaq-icon-sm" />
      {render_slot(@inner_block)}
    </p>
    """
  end

  defp hint_tone_class(:info), do: "zaq-field-hint--info"
  defp hint_tone_class(:success), do: "zaq-field-hint--success"
  defp hint_tone_class(:error), do: "zaq-field-hint--error"

  defp hint_icon(:info), do: "hero-information-circle"
  defp hint_icon(:success), do: "hero-check-circle"
  defp hint_icon(:error), do: "hero-exclamation-circle"
end
