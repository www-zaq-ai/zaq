defmodule ZaqWeb.Components.DesignSystem.PersonHeader do
  @moduledoc """
  People-facing composition of the shared BO page header without a sidebar.
  Settings is the approved no-personal-settings placeholder.
  Theme changes reuse the root preference handler; account actions remain People-only.
  """
  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1, theme_toggle: 1]

  alias ZaqWeb.Components.DesignSystem.{AccountMenu, PageHeader}

  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :display_name, :string, default: nil

  def person_header(assigns) do
    ~H"""
    <PageHeader.page_header id="people-header">
      <:brand><img src="/images/zaq.png" alt="ZAQ" class="zaq-header-brand" /></:brand>
      <:heading>
        <PageHeader.page_heading id="people-page" title={@title} description={@description} />
      </:heading>
      <:actions>
        <.theme_toggle />
        <nav
          id="people-header-menus"
          class="zaq-layout-inline relative"
          aria-label="Account"
        >
          <details id="people-settings-menu">
            <summary
              class="zaq-btn zaq-btn-secondary zaq-btn-icon zaq-header-menu-trigger"
              aria-label="Settings"
              title="Settings"
            >
              <.icon name="hero-cog-6-tooth" class="zaq-icon-sm" />
            </summary>
            <div class="zaq-card-default zaq-card-hover zaq-border-default zaq-header-menu-panel">
              <p class="zaq-text-h4">Personal settings</p>
              <p class="zaq-text-body-sm">No personal settings available yet.</p>
            </div>
          </details>
          <AccountMenu.account_menu
            id="people-profile-menu"
            display_name={@display_name}
            profile_url="/people/profile"
            logout_action="/people/session"
            logout_form_id="person-logout"
            profile_label="My profile"
            logout_label="Sign out"
          />
        </nav>
      </:actions>
    </PageHeader.page_header>
    """
  end
end
