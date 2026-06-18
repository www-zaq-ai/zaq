# lib/zaq_web/components/bo_layout.ex

defmodule ZaqWeb.Components.BOLayout do
  @moduledoc """
  Back office layout with collapsible sidebar and section dropdowns.
  """
  use Phoenix.Component

  import ZaqWeb.CoreComponents, only: [theme_toggle: 1]
  import ZaqWeb.Components.DesignSystem.AddonUpsellCard, only: [addon_upsell_card: 1]

  alias Zaq.Addons.FeatureStore
  alias Zaq.System
  use ZaqWeb, :verified_routes

  attr :current_user, :map, required: true
  attr :page_title, :string, default: "Dashboard"
  attr :current_path, :string, default: ""
  attr :flash, :map, default: %{}
  attr :auto_dismiss, :boolean, default: true
  attr :auto_dismiss_duration, :integer, default: 5000
  attr :features_version, :integer, default: 0
  attr :update_badge_enabled, :boolean, default: nil

  attr :portal_consent_live_enabled, :boolean,
    default: true,
    doc:
      "When false, skips embedding `PortalConsentLive` (use in Storybook or other static previews where LiveComponents cannot mount)."

  slot :inner_block, required: true

  def bo_layout(assigns) do
    app_version =
      :zaq
      |> Application.spec(:vsn)
      |> case do
        nil -> "dev"
        version -> to_string(version)
      end

    nav_sections = nav_sections(assigns.current_path, assigns.features_version)

    update_badge_enabled =
      case assigns.update_badge_enabled do
        value when is_boolean(value) -> value
        _ -> load_update_badge_enabled()
      end

    assigns =
      assigns
      |> assign(:app_version, app_version)
      |> assign(:update_badge_enabled, update_badge_enabled)
      |> assign(:nav_sections, nav_sections)
      |> assign(:nav_section_ids, Enum.map(nav_sections, & &1.id))

    ~H"""
    <div class="min-h-screen flex" style="background: var(--zaq-surface-color-base);" id="bo-root">
      <style>
                /* Sidebar transition */
                #bo-sidebar {
                  width: 240px;
                  transition: width 0.22s cubic-bezier(.4,0,.2,1);
                }
                #bo-sidebar.collapsed {
                  width: 60px;
                }
                #bo-main {
                  margin-left: 240px;
                  transition: margin-left 0.22s cubic-bezier(.4,0,.2,1);
                }
                #bo-main.collapsed {
                  margin-left: 60px;
                }

                #header-user-menu > summary,
                #header-settings-menu > summary {
                  list-style: none;
                }
                #header-user-menu > summary::-webkit-details-marker,
                #header-settings-menu > summary::-webkit-details-marker {
                  display: none;
                }

                /* Hide labels/sections when collapsed */
                #bo-sidebar.collapsed .nav-label,
                #bo-sidebar.collapsed .section-header-text,
                #bo-sidebar.collapsed .section-label,
                #bo-sidebar.collapsed .sidebar-github-copy,
                #bo-sidebar.collapsed .sidebar-version,
                #bo-sidebar.collapsed .logo-text {
                  opacity: 0;
                  width: 0;
                  overflow: hidden;
                  pointer-events: none;
                }

                #bo-sidebar.collapsed .sidebar-logo {
                  display: none;
                }

                #bo-sidebar.collapsed #sidebar-github-link {
                  width: fit-content;
                  margin-left: auto;
                  margin-right: auto;
                  padding: 0.5rem;
                  gap: 0;
                  align-items: center;
                }

                .version-update-badge {
                  display: inline-flex;
                  align-items: center;
                  justify-content: center;
                  width: 1.1rem;
                  height: 1.1rem;
                  border-radius: 9999px;
                  background: #ef4444;
                  animation: versionBadgePulse 3.2s ease-in-out infinite;
                }

                @keyframes versionBadgePulse {
                  0%, 100% {
                    opacity: 0.7;
                    transform: scale(0.92);
                  }

                  50% {
                    opacity: 1;
                    transform: scale(1);
                  }
                }

                /* Section dropdown */
                .section-items {
        overflow: hidden;
        transition: max-height 0.3s cubic-bezier(0.4, 0, 0.2, 1),
                  opacity 0.2s ease,
                  padding 0.2s ease;
        max-height: 500px;
        opacity: 1;
        }

        .section-items.closed {
        max-height: 0;
        opacity: 0;
        padding-top: 0;
        padding-bottom: 0;
        }

                /* Collapsed tooltip */
                #bo-sidebar.collapsed .section-header-wrap {
            position: relative;
            }

            #bo-sidebar.collapsed .nav-section:hover .section-items {
            position: absolute;
            left: 52px;
            top: 0;
            background: var(--zaq-surface-color-raised);
            min-width: 180px;
            max-height: 400px;
            overflow-y: auto;
            border-radius: 0 8px 8px 0;
            box-shadow: 4px 0 15px rgba(0,0,0,0.3);
            z-index: 50;
            opacity: 1 !important;
            max-height: 500px !important;
            padding: 8px;
            }

            #bo-sidebar.collapsed nav {
              overflow: visible;
            }
            #bo-sidebar.collapsed .nav-section {
            position: relative;
            }
                #bo-sidebar.collapsed .nav-item-wrap {
                  position: relative;
                }
                #bo-sidebar.collapsed .nav-item-wrap:hover .nav-tooltip {
                  display: block;
                }
                .nav-tooltip {
                  display: none;
                  position: absolute;
                  left: 52px;
                  top: 50%;
                  transform: translateY(-50%);
                  white-space: nowrap;
                  z-index: 100;
                  pointer-events: none;
                }

                /* Chevron rotation */
                .section-chevron {
                  transition: transform 0.2s ease;
                }
                .section-chevron.open {
                  transform: rotate(180deg);
                }

                /* Collapse toggle button */
                #sidebar-toggle {
                  transition: transform 0.22s ease;
                }
                #bo-sidebar.collapsed #sidebar-toggle {
                  transform: rotate(180deg);
                }

                /* Active section highlight when collapsed */
                #bo-sidebar.collapsed .active-section-wrap {
                  background: var(--zaq-surface-color-raised);
                  border-left: 2px solid var(--zaq-border-color-accent);
                  border-radius: var(--zaq-scale-8);
                }
                #bo-sidebar.collapsed button.active-section {
                  background: transparent;
                  border-left: none;
                }
      </style>
      
    <!-- Sidebar -->
      <aside
        id="bo-sidebar"
        data-section-ids={Enum.join(@nav_section_ids, ",")}
        class="fixed top-0 left-0 h-screen zaq-sidebar flex flex-col z-40 shadow-xl"
      >
        
    <!-- Logo + collapse toggle -->
        <div class="h-16 flex items-center justify-between px-3 flex-shrink-0 zaq-sidebar-header">
          <div class="flex items-center gap-2 min-w-0">
            <img
              src={~p"/images/zaq.png"}
              alt="ZAQ Logo"
              class="sidebar-logo h-8 w-8 flex-shrink-0 rounded-lg object-contain"
            />
            <span
              class="logo-text zaq-text-caption uppercase tracking-widest whitespace-nowrap transition-all duration-200"
              style="color: var(--zaq-text-color-body-tertiary);"
            >
              Back Office
            </span>
          </div>
          <button
            id="sidebar-toggle"
            onclick="toggleSidebar()"
            class="zaq-btn zaq-btn-ghost zaq-btn-icon"
            title="Toggle sidebar"
          >
            <svg
              class="w-4 h-4"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M15 19l-7-7 7-7" />
            </svg>
          </button>
        </div>
        
    <!-- Nav -->
        <nav class="flex-1 py-3 px-2 overflow-y-auto overflow-x-hidden space-y-0.5">
          
    <!-- Dashboard (standalone) -->
          <div class="nav-item-wrap">
            <a
              href={~p"/bo/dashboard"}
              class={[
                if(String.starts_with?(@current_path, "/bo/dashboard"),
                  do: "zaq-sidebar-nav-item-active",
                  else: "zaq-sidebar-nav-item"
                )
              ]}
            >
              <svg
                class="w-[18px] h-[18px] flex-shrink-0"
                fill="none"
                stroke="currentColor"
                stroke-width="1.8"
                viewBox="0 0 24 24"
              >
                <rect x="3" y="3" width="7" height="7" rx="1.5" />
                <rect x="14" y="3" width="7" height="7" rx="1.5" />
                <rect x="3" y="14" width="7" height="7" rx="1.5" />
                <rect x="14" y="14" width="7" height="7" rx="1.5" />
              </svg>
              <span class="nav-label zaq-text-body-sm transition-all duration-200 whitespace-nowrap">
                Dashboard
              </span>
            </a>
            <div class="nav-tooltip zaq-text-body-sm zaq-sidebar-nav-tooltip">Dashboard</div>
          </div>
          
    <!-- Sections -->
          <%= for section <- @nav_sections do %>
            <.nav_section
              id={section.id}
              label={section.label}
              icon={section.icon}
              current_path={@current_path}
              active={section.active}
              open={section.open}
            >
              <:item
                :for={item <- section.items}
                href={item.href}
                icon={item.icon}
                label={item.label}
                active={item.active}
                locked={Map.get(item, :locked, false)}
              />
            </.nav_section>
          <% end %>
        </nav>

        <div class="zaq-sidebar-footer p-3 flex-shrink-0 space-y-3">
          <a
            id="sidebar-github-link"
            href="https://github.com/www-zaq-ai/zaq"
            target="_blank"
            rel="noreferrer"
            class="group zaq-sidebar-footer-link"
          >
            <svg
              class="w-5 h-5 flex-shrink-0"
              viewBox="0 0 24 24"
              fill="currentColor"
              aria-hidden="true"
            >
              <path d="M12 .5C5.65.5.5 5.65.5 12c0 5.09 3.3 9.41 7.88 10.94.58.11.79-.25.79-.56 0-.28-.01-1.02-.01-2-3.2.7-3.87-1.54-3.87-1.54-.53-1.34-1.28-1.69-1.28-1.69-1.05-.72.08-.71.08-.71 1.16.08 1.77 1.2 1.77 1.2 1.03 1.77 2.71 1.26 3.37.97.1-.75.4-1.26.72-1.55-2.55-.29-5.23-1.28-5.23-5.68 0-1.26.45-2.29 1.19-3.1-.12-.3-.52-1.5.11-3.13 0 0 .97-.31 3.19 1.18A11.08 11.08 0 0 1 12 6.1c.98 0 1.97.13 2.9.39 2.22-1.49 3.19-1.18 3.19-1.18.64 1.63.24 2.83.12 3.13.74.81 1.19 1.84 1.19 3.1 0 4.41-2.68 5.39-5.24 5.68.41.35.77 1.03.77 2.08 0 1.51-.01 2.73-.01 3.1 0 .31.21.68.8.56A11.5 11.5 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5Z" />
            </svg>
            <div class="sidebar-github-copy min-w-0 transition-all duration-200">
              <p class="zaq-text-body-sm tracking-wide leading-tight">Star Zaq on GitHub</p>
              <p
                class="zaq-text-caption mt-0.5 leading-tight"
                style="color: var(--zaq-text-color-body-tertiary);"
              >
                Follow updates and support the project
              </p>
            </div>
          </a>
          <div class="flex items-center justify-end">
            <span
              class="sidebar-version zaq-text-caption"
              style="color: var(--zaq-text-color-body-tertiary);"
            >
              v{@app_version}
            </span>
            <a
              :if={@update_badge_enabled}
              id="sidebar-version-update-badge"
              href="https://github.com/www-zaq-ai/zaq/releases"
              target="_blank"
              rel="noopener noreferrer"
              class="ml-2"
              title="A newer version is available"
              aria-label="Open ZAQ releases"
            >
              <span class="version-update-badge" />
            </a>
          </div>
        </div>
      </aside>
      
    <!-- Main -->
      <main id="bo-main" class="flex-1">
        <!-- Header -->
        <header
          class="h-16 border-b flex items-center px-8 gap-6"
          style="background: var(--zaq-surface-color-raised); border-color: var(--zaq-border-color-default);"
        >
          <h1 class="zaq-text-h1 shrink-0" style="color: var(--zaq-text-color-body-default);">
            {@page_title}
          </h1>

          <div class="flex-1 min-w-0">
            <.live_component
              :if={@portal_consent_live_enabled}
              module={ZaqWeb.Live.BO.PortalConsentLive}
              id="portal-consent"
              current_user={@current_user}
            />
          </div>

          <div class="flex items-center gap-2 shrink-0">
            <.theme_toggle />
            <a
              id="header-notifications-link"
              href={~p"/bo/channels/notifications/logs"}
              class="zaq-btn zaq-btn-secondary zaq-btn-icon w-10 h-10"
              title="Notifications"
            >
              <svg
                class="w-5 h-5"
                fill="none"
                stroke="currentColor"
                stroke-width="1.8"
                viewBox="0 0 24 24"
              >
                <path
                  stroke-linecap="round"
                  stroke-linejoin="round"
                  d="M15 17h5l-1.405-1.405A2.032 2.032 0 0118 14.158V11a6.002 6.002 0 00-4-5.659V5a2 2 0 10-4 0v.341C7.67 6.165 6 8.388 6 11v3.159c0 .538-.214 1.055-.595 1.436L4 17h5m6 0v1a3 3 0 11-6 0v-1m6 0H9"
                />
              </svg>
            </a>

            <details id="header-settings-menu" class="relative">
              <summary
                id="header-settings-trigger"
                class="zaq-btn zaq-btn-secondary zaq-btn-icon list-none w-10 h-10 cursor-pointer"
              >
                <svg
                  class="w-5 h-5"
                  fill="none"
                  stroke="currentColor"
                  stroke-width="1.8"
                  viewBox="0 0 24 24"
                >
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
                  />
                  <path
                    stroke-linecap="round"
                    stroke-linejoin="round"
                    d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
                  />
                </svg>
              </summary>

              <div
                id="header-settings-dropdown"
                class="absolute right-0 top-[calc(100%+0.55rem)] w-56 rounded-xl border shadow-xl p-1.5 z-50"
                style="background: var(--zaq-surface-color-raised); border-color: var(--zaq-border-color-default);"
              >
                <a
                  id="header-settings-diagnostics-link"
                  href={~p"/bo/ai-diagnostics"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item flex items-center gap-2.5 rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  <svg
                    class="w-4 h-4 shrink-0"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M3.75 12h3l2.25-6 4.5 12 2.25-6h4.5"
                    />
                  </svg>
                  Diagnostics
                </a>
                <a
                  id="header-settings-prompt-templates-link"
                  href={~p"/bo/prompt-templates"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item flex items-center gap-2.5 rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  <svg
                    class="w-4 h-4 shrink-0"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M19.5 14.25v-2.625a3.375 3.375 0 0 0-3.375-3.375h-1.5A1.125 1.125 0 0 1 13.5 7.125v-1.5a3.375 3.375 0 0 0-3.375-3.375H8.25m0 12.75h7.5m-7.5 3H12M10.5 2.25H5.625c-.621 0-1.125.504-1.125 1.125v17.25c0 .621.504 1.125 1.125 1.125h12.75c.621 0 1.125-.504 1.125-1.125V11.25a9 9 0 0 0-9-9Z"
                    />
                  </svg>
                  Prompt templates
                </a>
                <a
                  id="header-settings-system-config-link"
                  href={~p"/bo/system-config"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item flex items-center gap-2.5 rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  <svg
                    class="w-4 h-4 shrink-0"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M21.75 6.75a4.5 4.5 0 0 1-4.884 4.484c-1.076-.091-2.264.071-2.95.904l-7.152 8.684a2.548 2.548 0 1 1-3.586-3.586l8.684-7.152c.833-.686.995-1.874.904-2.95a4.5 4.5 0 0 1 6.336-4.486l-3.276 3.276a3.004 3.004 0 0 0 2.25 2.25l3.276-3.276c.256.565.398 1.192.398 1.852Z"
                    />
                  </svg>
                  System config
                </a>
                <div class="my-1 h-px" style="background: var(--zaq-border-color-default);" />
                <a
                  id="header-settings-channels-link"
                  href={~p"/bo/channels"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item flex items-center gap-2.5 rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  <svg
                    class="w-4 h-4 shrink-0"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M7.217 10.907a2.25 2.25 0 1 0 0 2.186m0-2.186c.18.324.283.696.283 1.093s-.103.77-.283 1.093m0-2.186 9.566-5.314m-9.566 7.5 9.566 5.314m0 0a2.25 2.25 0 1 0 3.935 2.186 2.25 2.25 0 0 0-3.935-2.186Zm0-12.814a2.25 2.25 0 1 0 3.933-2.185 2.25 2.25 0 0 0-3.933 2.185Z"
                    />
                  </svg>
                  Channels
                </a>
                <div class="my-1 h-px" style="background: var(--zaq-border-color-default);" />
                <a
                  id="header-settings-users-link"
                  href={~p"/bo/users"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item flex items-center gap-2.5 rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  <svg
                    class="w-4 h-4 shrink-0"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M15 19.128a9.38 9.38 0 0 0 2.625.372 9.337 9.337 0 0 0 4.121-.952 4.125 4.125 0 0 0-7.533-2.493M15 19.128v-.003c0-1.113-.285-2.16-.786-3.07M15 19.128v.106A12.318 12.318 0 0 1 8.624 21c-2.331 0-4.512-.645-6.374-1.766l-.001-.109a6.375 6.375 0 0 1 11.964-3.07M12 6.375a3.375 3.375 0 1 1-6.75 0 3.375 3.375 0 0 1 6.75 0Zm8.25 2.25a2.625 2.625 0 1 1-5.25 0 2.625 2.625 0 0 1 5.25 0Z"
                    />
                  </svg>
                  Users
                </a>
                <a
                  id="header-settings-roles-link"
                  href={~p"/bo/roles"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item flex items-center gap-2.5 rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  <svg
                    class="w-4 h-4 shrink-0"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M9 12.75 11.25 15 15 9.75m-3-7.036A11.959 11.959 0 0 1 3.598 6 11.99 11.99 0 0 0 3 9.749c0 5.592 3.824 10.29 9 11.623 5.176-1.332 9-6.03 9-11.622 0-1.31-.21-2.571-.598-3.751h-.152c-3.196 0-6.1-1.248-8.25-3.285Z"
                    />
                  </svg>
                  Roles
                </a>
                <div class="my-1 h-px" style="background: var(--zaq-border-color-default);" />
                <a
                  id="header-settings-license-link"
                  href={~p"/bo/addons"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item flex items-center gap-2.5 rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  <svg
                    class="w-4 h-4 shrink-0"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="1.8"
                    viewBox="0 0 24 24"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M14.25 6.087c0-.355.186-.676.401-.959.221-.29.349-.634.349-1.003 0-1.036-1.007-1.875-2.25-1.875s-2.25.84-2.25 1.875c0 .369.128.713.349 1.003.215.283.401.604.401.959v0a.64.64 0 0 1-.657.643 48.39 48.39 0 0 1-4.163-.3c.186 1.613.293 3.25.315 4.907a.656.656 0 0 1-.658.663v0c-.355 0-.676-.186-.959-.401a1.647 1.647 0 0 0-1.003-.349c-1.036 0-1.875 1.007-1.875 2.25s.84 2.25 1.875 2.25c.369 0 .713-.128 1.003-.349.283-.215.604-.401.959-.401v0c.31 0 .555.26.532.57a48.039 48.039 0 0 1-.642 5.056c1.518.19 3.058.309 4.616.354a.64.64 0 0 0 .657-.643v0c0-.355-.186-.676-.401-.959a1.647 1.647 0 0 1-.349-1.003c0-1.035 1.008-1.875 2.25-1.875 1.243 0 2.25.84 2.25 1.875 0 .369-.128.713-.349 1.003-.215.283-.4.604-.4.959v0c0 .333.277.599.61.58a48.1 48.1 0 0 0 5.427-.63 48.05 48.05 0 0 0 .582-4.717.532.532 0 0 0-.533-.57v0c-.355 0-.676.186-.959.401-.29.221-.634.349-1.003.349-1.035 0-1.875-1.007-1.875-2.25s.84-2.25 1.875-2.25c.37 0 .713.128 1.003.349.283.215.604.401.96.401v0a.656.656 0 0 0 .658-.663 48.422 48.422 0 0 0-.37-5.36c-1.886.342-3.81.574-5.766.689a.578.578 0 0 1-.61-.58v0Z"
                    />
                  </svg>
                  Add-ons
                </a>
              </div>
            </details>

            <details id="header-user-menu" class="relative">
              <summary
                id="header-user-trigger"
                class="zaq-btn zaq-btn-secondary list-none flex items-center gap-2 rounded-lg px-2 py-1.5 cursor-pointer"
              >
                <span
                  class="zaq-text-body-sm w-8 h-8 rounded-lg grid place-items-center font-bold border"
                  style="background: color: var(--zaq-text-color-body-accent); border-color: var(--zaq-border-color-accent);"
                >
                  {String.first(@current_user.username) |> String.upcase()}
                </span>
                <span class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-default);">
                  {@current_user.username}
                </span>
              </summary>

              <div
                id="header-user-dropdown"
                class="absolute right-0 top-[calc(100%+0.55rem)] w-56 rounded-xl border shadow-xl p-1.5 z-50"
                style="background: var(--zaq-surface-color-raised); border-color: var(--zaq-border-color-default);"
              >
                <a
                  id="header-profile-link"
                  href={~p"/bo/profile"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item block rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  Profile
                </a>
                <div class="my-1 h-px" style="background: var(--zaq-border-color-default);" />
                <form id="header-logout-form" method="post" action={~p"/bo/session"}>
                  <input type="hidden" name="_method" value="delete" />
                  <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                  <button
                    id="header-logout-button"
                    type="submit"
                    class="zaq-text-body-sm zaq-dropdown-menu-item w-full text-left rounded-lg px-3 py-2 cursor-pointer"
                    style="color: var(--zaq-text-color-body-danger);"
                  >
                    Logout
                  </button>
                </form>
              </div>
            </details>
          </div>
        </header>
        <!-- Content -->
        <div class="p-8">
          <div
            :if={Phoenix.Flash.get(@flash, :info)}
            id="flash-info"
            class="zaq-feedback-banner zaq-success zaq-text-body"
            phx-hook="FlashAutoDismiss"
            data-auto-dismiss-duration={if @auto_dismiss, do: @auto_dismiss_duration, else: 0}
          >
            <span class="zaq-feedback-icon">
              <svg fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
                <path d="M5 13l4 4L19 7" />
              </svg>
            </span>
            <span class="zaq-feedback-body">{flash_body(Phoenix.Flash.get(@flash, :info))}</span>
            <button
              type="button"
              phx-click="lv:clear-flash"
              phx-value-key="info"
              data-flash-dismiss
              class="zaq-feedback-dismiss"
              aria-label="Dismiss"
            >
              <svg fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
                <path d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
          <div
            :if={Phoenix.Flash.get(@flash, :error)}
            id="flash-error"
            class="zaq-feedback-banner zaq-danger zaq-text-body"
            phx-hook="FlashAutoDismiss"
            data-auto-dismiss-duration={if @auto_dismiss, do: @auto_dismiss_duration, else: 0}
          >
            <span class="zaq-feedback-icon">
              <svg fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
                <circle cx="12" cy="12" r="10" /><path d="M12 8v4m0 4h.01" />
              </svg>
            </span>
            <span class="zaq-feedback-body">{flash_body(Phoenix.Flash.get(@flash, :error))}</span>
            <button
              type="button"
              phx-click="lv:clear-flash"
              phx-value-key="error"
              data-flash-dismiss
              class="zaq-feedback-dismiss"
              aria-label="Dismiss"
            >
              <svg fill="none" stroke="currentColor" stroke-width="2" viewBox="0 0 24 24">
                <path d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>
    """
  end

  # Renders a flash message, turning the literal phrase "user portal" into a link
  # to the configured portal. The message is HTML-escaped first, so interpolated
  # values (folder names, agent names, …) can never inject markup — only the
  # trusted anchor is added afterwards.
  #
  # This is a deliberate heuristic coupled to the wording of
  # `Zaq.UserPortal.provision_error/1` (which emits "… user portal …"). Flashes
  # that rephrase the term ("ZAQ portal", "the portal") are intentionally left
  # un-linkified — the split simply finds no match and returns the escaped text.
  defp flash_body(nil), do: nil

  defp flash_body(message) when is_binary(message) do
    escaped = message |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

    case String.split(escaped, "user portal", parts: 2) do
      [before, rest] ->
        href =
          Zaq.UserPortal.base_url() |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

        Phoenix.HTML.raw(
          before <>
            ~s(<a href="#{href}" target="_blank" rel="noopener noreferrer" class="underline">user portal</a>) <>
            rest
        )

      _ ->
        Phoenix.HTML.raw(escaped)
    end
  end

  # ── Nav Section with dropdown ────────────────────────────────────────

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :current_path, :string, required: true
  attr :open, :boolean, default: false
  attr :icon, :string, required: true
  attr :active, :boolean, default: false

  slot :item do
    attr :href, :string, required: true
    attr :icon, :string, required: true
    attr :label, :string, required: true
    attr :active, :boolean
    attr :locked, :boolean
  end

  defp nav_section(assigns) do
    ~H"""
    <div
      class={[
        "mt-1",
        if(@active,
          do: "active-section-wrap",
          else: if(@open, do: "open-section-wrap zaq-sidebar-open-section", else: "")
        )
      ]}
      id={@id}
    >
      <%!-- Section header / toggle --%>
      <button
        onclick={"toggleSection('#{@id}')"}
        class={[
          "w-full flex items-center justify-between group zaq-sidebar-nav-section",
          if(@active, do: "active-section", else: "")
        ]}
      >
        <div class="flex items-center gap-2.5 min-w-0">
          <%!-- Section Icon --%>
          <.section_icon icon={@icon} active={@active} />
          <span class="section-label zaq-text-caption uppercase tracking-widest transition-all duration-200 whitespace-nowrap">
            {@label}
          </span>
        </div>
        <svg
          id={@id <> "-chevron"}
          class={"section-chevron w-3 h-3 flex-shrink-0 section-header-text #{if @open, do: "open", else: ""}"}
          fill="none"
          stroke="currentColor"
          stroke-width="2.5"
          viewBox="0 0 24 24"
        >
          <path stroke-linecap="round" stroke-linejoin="round" d="M19 9l-7 7-7-7" />
        </svg>
      </button>

      <%!-- Items --%>
      <div id={@id <> "-items"} class={"section-items #{if !@open, do: "closed", else: ""}"}>
        <%= for item <- @item do %>
          <div class="nav-item-wrap">
            <a
              href={item.href}
              class={[
                if(Map.get(item, :locked),
                  do: "zaq-sidebar-nav-item-locked",
                  else:
                    if(item.active,
                      do: "zaq-sidebar-nav-item-active",
                      else: "zaq-sidebar-nav-item"
                    )
                )
              ]}
            >
              <.nav_icon icon={item.icon} />
              <span class="nav-label zaq-text-body-sm transition-all duration-200 whitespace-nowrap flex-1">
                {item.label}
              </span>
              <svg
                :if={Map.get(item, :locked)}
                class="nav-label w-3 h-3 flex-shrink-0 opacity-50"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <rect x="3" y="11" width="18" height="11" rx="2" ry="2" />
                <path d="M7 11V7a5 5 0 0 1 10 0v4" />
              </svg>
            </a>
            <div class="nav-tooltip zaq-text-body-sm zaq-sidebar-nav-tooltip">{item.label}</div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp section_icon(assigns) do
    assigns = assign(assigns, :icon_class, "w-4 h-4 flex-shrink-0")

    ~H"""
    <ZaqWeb.Components.IconRegistry.icon namespace="section" name={@icon} class={@icon_class} />
    """
  end

  # ── Icon component ───────────────────────────────────────────────────

  attr :icon, :string, required: true

  defp nav_icon(assigns) do
    ~H"""
    <ZaqWeb.Components.IconRegistry.icon
      namespace="nav"
      name={@icon}
      class="w-[18px] h-[18px] flex-shrink-0"
    />
    """
  end

  attr :status, :any, required: true

  def status_badge(assigns) do
    ~H"""
    <span
      :if={@status == :idle}
      class="zaq-pill zaq-text-caption zaq-pill--elevated"
    >
      idle
    </span>
    <span
      :if={@status == :loading}
      class="zaq-pill zaq-text-caption zaq-pill--accent zaq-pill--pulse"
    >
      testing…
    </span>
    <span
      :if={@status == :ok}
      class="zaq-pill zaq-text-caption zaq-pill--success"
    >
      ✓ connected
    </span>
    <span
      :if={is_tuple(@status) and elem(@status, 0) == :error}
      class="zaq-pill zaq-text-caption zaq-pill--danger"
    >
      ✗ error
    </span>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :truncate, :boolean, default: false
  attr :hint, :string, default: nil

  def config_row(assigns) do
    ~H"""
    <div class="flex justify-between items-center gap-2">
      <div class="flex items-center gap-1 shrink-0">
        <p class="font-mono text-[0.7rem] text-black/40">{@label}</p>
        <div :if={@hint} class="relative group">
          <div class="w-3.5 h-3.5 rounded-full border border-black/20 text-black/30 flex items-center justify-center cursor-default text-[0.55rem] font-bold leading-none">
            i
          </div>
          <div class="absolute bottom-full left-1/2 -translate-x-1/2 mb-1.5 z-10 hidden group-hover:block">
            <div class="zaq-bg-ink text-white font-mono text-[0.65rem] px-2.5 py-1.5 rounded-lg whitespace-nowrap shadow-lg">
              {@hint}
            </div>
            <div class="w-0 h-0 border-l-4 border-r-4 border-t-4 border-l-transparent border-r-transparent border-t-[var(--zaq-color-ink)] mx-auto" />
          </div>
        </div>
      </div>
      <p class={[
        "font-mono text-[0.7rem] text-black text-right",
        if(@truncate, do: "truncate max-w-[120px]", else: "")
      ]}>
        {@value}
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :status, :any, default: nil
  attr :event, :string, default: nil
  attr :button_label, :string, default: "Test Connection"
  slot :inner_block, required: true
  slot :footer_extra

  def diagnostic_card(assigns) do
    ~H"""
    <div class="bg-white rounded-xl border border-black/10 p-5 flex flex-col">
      <div class="flex items-center justify-between mb-4">
        <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider">{@label}</p>
        <.status_badge :if={@status != nil} status={@status} />
      </div>
      <div class="space-y-2 mb-4">
        {render_slot(@inner_block)}
      </div>
      <div :if={@event} class="mt-auto border-t border-black/5 pt-3">
        <button
          phx-click={@event}
          disabled={@status == :loading}
          class="w-full font-mono text-[0.75rem] font-bold px-4 py-2 rounded-lg bg-[#3c4b64] text-white hover:bg-[#3c4b64]/80 disabled:opacity-40 transition-colors"
        >
          {if @status == :loading, do: "Testing…", else: @button_label}
        </button>
        <p
          :if={is_tuple(@status) and elem(@status, 0) == :error}
          class="font-mono text-[0.7rem] text-red-500 mt-2 break-all"
        >
          {elem(@status, 1)}
        </p>
        {render_slot(@footer_extra)}
      </div>
    </div>
    """
  end

  @doc """
  Renders a centered "feature not enabled" gate card.

  ## Attributes

    * `:feature_name` - Human-readable feature name shown in the description.
    * `:message` - Optional override for the description line.
  """
  attr :feature_name, :string, required: true
  attr :message, :string, default: nil

  def feature_gate(assigns) do
    assigns =
      update(assigns, :message, fn
        nil ->
          "The #{String.downcase(assigns.feature_name)} feature is not enabled by your current add-ons. Contact your administrator."

        msg ->
          msg
      end)

    ~H"""
    <div class="flex items-center justify-center min-h-[60vh]">
      <.addon_upsell_card
        variant={:gate}
        title="Feature Not Enabled"
        message={@message}
        link_href={~p"/bo/addons"}
      >
        <:icon>
          <ZaqWeb.CoreComponents.icon name="hero-exclamation-triangle" class="w-5 h-5" />
        </:icon>
      </.addon_upsell_card>
    </div>
    """
  end

  defp feature_locked?(feature, _features_version) do
    not FeatureStore.feature_loaded?(feature)
  end

  defp nav_sections(current_path, features_version) do
    [
      %{
        id: "section-ai",
        label: "AI",
        icon: "ai",
        active: ai_section_active?(current_path),
        open: ai_section_active?(current_path),
        items: [
          %{
            href: ~p"/bo/agents",
            icon: "conversations",
            label: "Agents",
            active: current_path == "/bo/agents"
          }
        ]
      },
      %{
        id: "section-data",
        label: "Data",
        icon: "ai",
        active: data_section_active?(current_path),
        open: data_section_active?(current_path),
        items: [
          %{
            href: ~p"/bo/ingestion",
            icon: "ingestion",
            label: "Ingestion",
            active: current_path == "/bo/ingestion"
          },
          %{
            href: ~p"/bo/people",
            icon: "people",
            label: "People Directory",
            active: String.starts_with?(current_path, "/bo/people")
          },
          %{
            href: ~p"/bo/ontology",
            icon: "ontology",
            label: "Ontology",
            active: String.starts_with?(current_path, "/bo/ontology"),
            locked: feature_locked?("ontology", features_version)
          },
          %{
            href: ~p"/bo/knowledge-gap",
            icon: "knowledge_gap",
            label: "Knowledge Gap",
            active: current_path == "/bo/knowledge-gap",
            locked: feature_locked?("knowledge_gap", features_version)
          }
        ]
      },
      %{
        id: "section-communication",
        label: "Communication",
        icon: "communication",
        active: communication_section_active?(current_path),
        open: communication_section_active?(current_path),
        items: [
          %{
            href: ~p"/bo/chat",
            icon: "conversations",
            label: "Chat",
            active: current_path == "/bo/chat"
          },
          %{
            href: ~p"/bo/history",
            icon: "history",
            label: "History",
            active: current_path == "/bo/history"
          }
        ]
      }
    ]
  end

  defp data_section_active?(current_path) do
    String.starts_with?(current_path, "/bo/ai") or
      String.starts_with?(current_path, "/bo/prompt") or
      String.starts_with?(current_path, "/bo/ingestion") or
      String.starts_with?(current_path, "/bo/people") or
      String.starts_with?(current_path, "/bo/ontology") or
      current_path == "/bo/knowledge-gap"
  end

  defp ai_section_active?(current_path) do
    current_path == "/bo/agents"
  end

  defp communication_section_active?(current_path) do
    String.starts_with?(current_path, "/bo/channels") or
      current_path in ["/bo/chat", "/bo/history"]
  end

  defp load_update_badge_enabled do
    System.get_config("ui.update_badge_enabled") == "true"
  rescue
    DBConnection.OwnershipError -> false
    DBConnection.ConnectionError -> false
  catch
    :exit, _reason -> false
  end
end
