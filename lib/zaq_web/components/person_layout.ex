defmodule ZaqWeb.Components.PersonLayout do
  @moduledoc "Minimal public People shell, composed from ZAQ design-system primitives."
  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.Button

  attr :flash, :map, required: true
  attr :authenticated, :boolean, default: false
  slot :inner_block, required: true

  def person_layout(assigns) do
    assigns = assign(assigns, :logout_form, to_form(%{}))

    ~H"""
    <div
      class="min-h-screen zaq-layout-stack zaq-layout-content-inset"
      style="background: var(--zaq-surface-color-base); color: var(--zaq-text-color-body-default)"
    >
      <header class="zaq-layout-inline justify-between flex-wrap">
        <span class="zaq-text-h2">ZAQ</span>
        <nav :if={@authenticated} aria-label="People" class="zaq-layout-inline">
          <Button.button href="/people/profile" variant={:ghost} aria-current="page">Profile</Button.button>
          <.form for={@logout_form} id="person-logout" action="/people/session" method="delete">
            <Button.button type="submit" variant={:secondary}>Sign out</Button.button>
          </.form>
        </nav>
      </header>
      <main class="w-full max-w-lg mx-auto zaq-layout-stack">
        <p
          :if={Phoenix.Flash.get(@flash, :info)}
          role="status"
          class="zaq-text-body"
          style="color: var(--zaq-text-color-body-success)"
        >
          {Phoenix.Flash.get(@flash, :info)}
        </p>
        <p
          :if={Phoenix.Flash.get(@flash, :error)}
          role="alert"
          class="zaq-text-body"
          style="color: var(--zaq-text-color-body-danger)"
        >
          {Phoenix.Flash.get(@flash, :error)}
        </p>
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end
end
