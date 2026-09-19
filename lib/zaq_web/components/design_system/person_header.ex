defmodule ZaqWeb.Components.DesignSystem.PersonHeader do
  @moduledoc """
  People-facing composition of the shared BO page header without a sidebar.
   Settings exposes caller-authorized People destinations.
  Theme changes reuse the root preference handler; account actions remain People-only.
  """
  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1, theme_toggle: 1]

  alias ZaqWeb.Components.DesignSystem.{AccountMenu, PageHeader}

  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :display_name, :string, default: nil
  attr :history_access, :boolean, default: false
  attr :credentials_access, :boolean, default: true

  def person_header(assigns) do
    ~H"""
    <PageHeader.page_header
      id="people-header"
      class="flex-nowrap gap-2 sm:flex-wrap sm:gap-4"
      identity_class="gap-2 sm:gap-4"
      actions_class="flex-nowrap gap-2 sm:gap-4"
    >
      <:brand><img src="/images/zaq.png" alt="ZAQ" class="zaq-header-brand" /></:brand>
      <:heading>
        <div class="zaq-person-header-heading min-w-0 flex-1">
          <PageHeader.page_heading
            id="people-page"
            title={@title}
            description={@description}
            description_class="hidden sm:block"
          />
        </div>
      </:heading>
      <:actions>
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
              <div class="zaq-layout-stack-tight">
                <p class="zaq-text-h4">Appearance</p>
                <.theme_toggle />
              </div>
              <div
                :if={@history_access || @credentials_access}
                class="zaq-account-divider"
              />
              <p :if={@history_access || @credentials_access} class="zaq-text-h4">
                Personal settings
              </p>
              <.link
                :if={@history_access}
                id="people-conversations-link"
                navigate="/people/history"
                class="zaq-btn zaq-btn-ghost"
              >Conversations</.link>
              <.link
                :if={@credentials_access}
                id="people-credentials-link"
                navigate="/people/credentials"
                class="zaq-btn zaq-btn-ghost"
              >Credentials</.link>
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
            name_class="hidden sm:inline"
          />
        </nav>
      </:actions>
    </PageHeader.page_header>
    """
  end
end
