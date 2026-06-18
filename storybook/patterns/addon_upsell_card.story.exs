defmodule Storybook.Patterns.AddonUpsellCard do
  @moduledoc false
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  import ZaqWeb.Components.DesignSystem.AddonUpsellCard, only: [addon_upsell_card: 1]

  def description,
    do:
      "Add-on upsell pattern: icon slot, title, message, primary link (ZaqWeb.Components.DesignSystem.AddonUpsellCard). Parent owns layout (full-page gate vs dashboard column)."

  def render(assigns) do
    ~H"""
    <div
      class="zaq-text-body flex flex-col gap-12"
      style="padding: var(--zaq-scale-32); max-width: 720px;"
    >
      <div>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-16);"
        >
          <code>:gate</code> — full-page parent centers the same inner card below
        </p>
        <.addon_upsell_card
          variant={:gate}
          title="Feature Not Enabled"
          message="The ontology feature is not enabled by your current add-ons. Contact your administrator."
          link_href="/bo/addons"
        >
          <:icon>
            <ZaqWeb.CoreComponents.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          </:icon>
        </.addon_upsell_card>
      </div>

      <div>
        <p
          class="zaq-text-caption"
          style="color: var(--zaq-text-color-body-tertiary); margin-bottom: var(--zaq-scale-16);"
        >
          <code>:inline</code> — same card chrome; dashboard parent places it in the column
        </p>
        <.addon_upsell_card
          variant={:inline}
          title="No Add-ons"
          message="Running in basic mode"
          link_href="/bo/addons"
        >
          <:icon>
            <ZaqWeb.CoreComponents.icon name="hero-exclamation-triangle" class="w-5 h-5" />
          </:icon>
        </.addon_upsell_card>
      </div>
    </div>
    """
  end
end
