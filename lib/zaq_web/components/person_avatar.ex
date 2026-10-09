defmodule ZaqWeb.Components.PersonAvatar do
  @moduledoc "Reusable initials avatar with a deterministic, channel-independent Person color."
  use Phoenix.Component

  attr :name, :string, required: true
  attr :person_id, :integer, default: nil
  attr :identity_key, :string, default: "unknown"

  def avatar(assigns) do
    key = if assigns.person_id, do: "person:#{assigns.person_id}", else: assigns.identity_key
    <<value::unsigned-32, _::binary>> = :crypto.hash(:sha256, key)

    initials =
      assigns.name
      |> String.split()
      |> Enum.take(2)
      |> Enum.map_join(&String.first/1)
      |> String.upcase()

    assigns = assign(assigns, initials: initials, hue: rem(value, 360))

    ~H"""
    <span
      class="flex items-center justify-center shrink-0 w-8 h-8 rounded-full zaq-text-body-sm"
      style={"background: color-mix(in srgb, hsl(#{@hue} 70% 55%) 24%, var(--zaq-surface-color-elevated)); color: var(--zaq-text-color-body-default);"}
      title={@name}
      aria-label={@name}
      data-testid="message-initials"
    >{@initials}</span>
    """
  end
end
