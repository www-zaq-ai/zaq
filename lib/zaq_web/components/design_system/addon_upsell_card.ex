defmodule ZaqWeb.Components.DesignSystem.AddonUpsellCard do
  @moduledoc """
  Shared upsell-to-add-ons card: custom icon (slot), title, body copy, and primary link.

  **Placement** (centering vs sidebar) stays with the parent; this component is only the card.

  * `:variant` — `:gate` and `:inline` use the **same** inner card chrome (`zaq-*` tokens).
    The atom is for call-site semantics only (feature gate vs dashboard column); styling is identical.
  """

  use Phoenix.Component

  attr :variant, :atom,
    default: :inline,
    values: [:inline, :gate],
    doc:
      "`:gate` or `:inline` — same visual chrome; parent controls layout (full-page center vs column)."

  attr :title, :string, required: true
  attr :message, :string, required: true
  attr :link_href, :string, required: true
  attr :link_text, :string, default: "View Add-ons"

  slot :icon, required: true, doc: "Icon or illustration for this placement."

  def addon_upsell_card(assigns) do
    ~H"""
    <div
      class={wrapper_class(@variant)}
      style={surface_style(@variant)}
    >
      <div
        class={icon_shell_class(@variant)}
        style={icon_shell_surface_style(@variant)}
      >
        {render_slot(@icon)}
      </div>
      <p class={title_class(@variant)} style={title_color_style(@variant)}>
        {@title}
      </p>
      <p class={message_class(@variant)} style={message_color_style(@variant)}>
        {@message}
      </p>
      <.link
        href={@link_href}
        class={link_class(@variant)}
        data-testid="addon-upsell-cta"
      >
        {@link_text}
      </.link>
    </div>
    """
  end

  defp wrapper_class(_variant),
    do:
      "zaq-card-default zaq-border-default flex flex-col items-center text-center max-w-md w-full gap-4"

  defp icon_shell_class(_variant), do: "w-10 h-10 rounded-lg grid place-items-center mx-auto"

  defp title_class(_variant), do: "zaq-text-h4"

  defp message_class(_variant), do: "zaq-text-body-sm"

  defp link_class(_variant), do: "zaq-btn zaq-btn-primary zaq-btn-text_label-default"

  defp surface_style(_variant), do: "background: var(--zaq-surface-color-raised)"

  defp icon_shell_surface_style(_variant), do: "background: var(--zaq-surface-color-elevated)"

  defp title_color_style(_variant), do: "color: var(--zaq-text-color-body-default)"

  defp message_color_style(_variant), do: "color: var(--zaq-text-color-body-secondary)"
end
