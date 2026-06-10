# lib/zaq_web/components/bo_layout.ex

defmodule ZaqWeb.Components.BOLayout do
  @moduledoc """
  Back office layout with collapsible sidebar and section dropdowns.
  """
  use Phoenix.Component
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
          class="h-16 border-b flex items-center justify-between px-8"
          style="background: var(--zaq-surface-color-raised); border-color: var(--zaq-border-color-default);"
        >
          <h1 class="zaq-text-h1" style="color: var(--zaq-text-color-body-default);">
            {@page_title}
          </h1>

          <div class="flex items-center gap-2">
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
                  class="zaq-text-body-sm zaq-dropdown-menu-item block rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  Diagnostics
                </a>
                <a
                  id="header-settings-prompt-templates-link"
                  href={~p"/bo/prompt-templates"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item block rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  Prompt templates
                </a>
                <a
                  id="header-settings-system-config-link"
                  href={~p"/bo/system-config"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item block rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  System config
                </a>
                <div class="my-1 h-px" style="background: var(--zaq-border-color-default);" />
                <a
                  id="header-settings-channels-link"
                  href={~p"/bo/channels"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item block rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  Channels
                </a>
                <div class="my-1 h-px" style="background: var(--zaq-border-color-default);" />
                <a
                  id="header-settings-users-link"
                  href={~p"/bo/users"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item block rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  Users
                </a>
                <a
                  id="header-settings-roles-link"
                  href={~p"/bo/roles"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item block rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
                  Roles
                </a>
                <div class="my-1 h-px" style="background: var(--zaq-border-color-default);" />
                <a
                  id="header-settings-license-link"
                  href={~p"/bo/addons"}
                  class="zaq-text-body-sm zaq-dropdown-menu-item block rounded-lg px-3 py-2"
                  style="color: var(--zaq-text-color-body-default);"
                >
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
            class="mb-4 rounded-xl zaq-success zaq-text-body px-4 py-3 flex items-center gap-2"
            phx-hook="FlashAutoDismiss"
            data-auto-dismiss-duration={if @auto_dismiss, do: @auto_dismiss_duration, else: 0}
          >
            <svg
              class="w-4 h-4 shrink-0"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
            >
              <path d="M5 13l4 4L19 7" />
            </svg>
            <span class="flex-1">{Phoenix.Flash.get(@flash, :info)}</span>
            <button
              phx-click="lv:clear-flash"
              phx-value-key="info"
              data-flash-dismiss
              class="ml-auto opacity-60 hover:opacity-100 cursor-pointer"
              aria-label="Dismiss"
            >
              <svg
                class="w-4 h-4"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <path d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
          <div
            :if={Phoenix.Flash.get(@flash, :error)}
            id="flash-error"
            class="mb-4 rounded-xl zaq-danger zaq-text-body px-4 py-3 flex items-center gap-2"
            phx-hook="FlashAutoDismiss"
            data-auto-dismiss-duration={if @auto_dismiss, do: @auto_dismiss_duration, else: 0}
          >
            <svg
              class="w-4 h-4 shrink-0"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
            >
              <circle cx="12" cy="12" r="10" /><path d="M12 8v4m0 4h.01" />
            </svg>
            <span class="flex-1">{Phoenix.Flash.get(@flash, :error)}</span>
            <button
              phx-click="lv:clear-flash"
              phx-value-key="error"
              data-flash-dismiss
              class="ml-auto opacity-60 hover:opacity-100 cursor-pointer"
              aria-label="Dismiss"
            >
              <svg
                class="w-4 h-4"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
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
      class="font-mono text-[0.7rem] px-2 py-1 rounded bg-black/5 text-black/30"
    >
      idle
    </span>
    <span
      :if={@status == :loading}
      class="font-mono text-[0.7rem] px-2 py-1 rounded bg-amber-100 text-amber-600"
    >
      testing…
    </span>
    <span
      :if={@status == :ok}
      class="font-mono text-[0.7rem] px-2 py-1 rounded bg-emerald-100 text-emerald-700"
    >
      ✓ connected
    </span>
    <span
      :if={is_tuple(@status) and elem(@status, 0) == :error}
      class="font-mono text-[0.7rem] px-2 py-1 rounded bg-red-100 text-red-600"
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
      <div
        class="zaq-card-default zaq-border-default flex flex-col items-center text-center max-w-md w-full"
        style="background: var(--zaq-surface-color-raised)"
      >
        <div
          class="w-10 h-10 rounded-lg grid place-items-center mx-auto"
          style="background: var(--zaq-surface-color-elevated)"
        >
          <ZaqWeb.CoreComponents.icon
            name="hero-exclamation-triangle"
            class="w-5 h-5"
          />
        </div>
        <p class="zaq-text-h4" style="color: var(--zaq-text-color-body-default)">
          Feature Not Enabled
        </p>
        <p class="zaq-text-body-sm" style="color: var(--zaq-text-color-body-secondary)">
          {@message}
        </p>
        <.link
          href={~p"/bo/addons"}
          class="zaq-btn zaq-btn-primary zaq-btn-text_label-default"
        >
          View Add-ons
        </.link>
      </div>
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
