defmodule ZaqWeb.Components.DesignSystem.PersonHeader do
  @moduledoc """
  People-facing composition of the shared BO page header without a sidebar.
  Settings derives People destinations consistently from the person's permissions.
  Theme changes reuse the root preference handler; account actions remain People-only.
  """
  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [icon: 1, theme_toggle: 1]

  alias ZaqWeb.Components.DesignSystem.{AccountMenu, CardShell, PageHeader}

  attr :title, :string, required: true
  attr :description, :string, default: nil
  attr :display_name, :string, default: nil
  attr :person_permissions, :any, required: true

  def person_header(assigns) do
    assigns = assign(assigns, :history_access, history_access?(assigns.person_permissions))

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
            <CardShell.card_shell
              id="people-settings-panel"
              as={:div}
              class="zaq-card-hover zaq-header-menu-panel"
            >
              <div class="zaq-layout-stack-tight">
                <p class="zaq-text-h4">Appearance</p>
                <.theme_toggle />
              </div>
              <div class="zaq-account-divider" />
              <p class="zaq-text-h4">Personal settings</p>
              <.link
                :if={@history_access}
                id="people-conversations-link"
                navigate="/people/history"
                class="zaq-btn zaq-btn-ghost"
              >Conversations</.link>
              <.link
                id="people-credentials-link"
                navigate="/people/credentials"
                class="zaq-btn zaq-btn-ghost"
              >Credentials</.link>
            </CardShell.card_shell>
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

  defp history_access?(%MapSet{} = permissions) do
    Enum.all?(
      [:access_profile, :access_message_history],
      &MapSet.member?(permissions, &1)
    )
  end

  defp history_access?(_permissions), do: false
end
