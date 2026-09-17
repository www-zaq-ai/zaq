defmodule Storybook.Layouts.AuthLayout do
  use PhoenixStorybook.Story, :page
  use Phoenix.Component

  alias ZaqWeb.Components.DesignSystem.AuthLayout
  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Components.DesignSystem.Input, as: DSInput
  alias ZaqWeb.Components.DesignSystem.Link, as: DSLink

  def description,
    do:
      "Centered auth page shell for BO login and password-reset flows (`ZaqWeb.Components.DesignSystem.AuthLayout`)."

  def render(assigns) do
    ~H"""
    <div style="height: 720px; overflow: auto; border: 1px solid rgba(0,0,0,0.08); border-radius: 0.75rem;">
      <AuthLayout.auth_layout subtitle="Authorization Required">
        <:header_icon>
          <img src="/images/zaq.png" alt="ZAQ" class="zaq-auth-logo-img" />
        </:header_icon>

        <.form for={%{}} id="story-auth-login-form" class="zaq-layout-stack">
          <DSInput.input
            name="username"
            label="Username or Email"
            value=""
            placeholder="username or email"
          />
          <DSButton.button type="button" variant={:primary} class="w-full uppercase">
            Sign In to Dashboard
          </DSButton.button>
        </.form>

        <:footer>
          <p class="zaq-text-caption uppercase" style="color: var(--zaq-text-color-body-tertiary)">
            ZAQ Back Office &copy; 2026 |
            <DSLink.nav_link destination="https://zaq.ai" tone={:accent} external={true} size={:sm}>
              zaq.ai
            </DSLink.nav_link>
          </p>
        </:footer>
      </AuthLayout.auth_layout>
    </div>
    """
  end
end
