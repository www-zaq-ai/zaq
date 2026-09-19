defmodule ZaqWeb.Components.PersonLayout do
  @moduledoc "Minimal public People shell, composed from ZAQ design-system primitives."
  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.{Button, FeedbackBanner}

  attr :flash, :map, required: true
  attr :authenticated, :boolean, default: false
  attr :content_width, :atom, default: :narrow, values: [:narrow, :wide]
  slot :inner_block, required: true

  slot :header,
    doc: "Optional shared page header; default keeps the narrow login shell unchanged."

  def person_layout(assigns) do
    assigns = assign(assigns, :logout_form, to_form(%{}))

    ~H"""
    <div
      class={[
        "min-h-screen zaq-layout-stack zaq-text-body",
        @header == [] && "zaq-layout-content-inset"
      ]}
      style="background: var(--zaq-surface-color-base); color: var(--zaq-text-color-body-default)"
    >
      {render_slot(@header)}
      <header :if={@header == []} class="zaq-layout-inline justify-between flex-wrap">
        <span class="zaq-text-h2">ZAQ</span>
        <nav :if={@authenticated} aria-label="People" class="zaq-layout-inline">
          <Button.button href="/people/profile" variant={:ghost} aria-current="page">Profile</Button.button>
          <.form for={@logout_form} id="person-logout" action="/people/session" method="delete">
            <Button.button type="submit" variant={:secondary}>Sign out</Button.button>
          </.form>
        </nav>
      </header>
      <main class={[
        "w-full min-w-0 mx-auto zaq-layout-stack",
        @header != [] && "zaq-layout-content-inset",
        if(@content_width == :wide, do: "max-w-6xl", else: "max-w-lg")
      ]}>
        <FeedbackBanner.feedback_banner
          :if={message = Phoenix.Flash.get(@flash, :info)}
          kind={:info}
          message={message}
        />
        <FeedbackBanner.feedback_banner
          :if={message = Phoenix.Flash.get(@flash, :error)}
          kind={:error}
          message={message}
        />
        {render_slot(@inner_block)}
      </main>
    </div>
    """
  end
end
