# lib/zaq_web/components/bo_layout.ex

defmodule ZaqWeb.Components.BOLayout do
  @moduledoc """
  Back office layout with collapsible sidebar and section dropdowns.
  """
  use Phoenix.Component
  alias Zaq.License.FeatureStore
  use ZaqWeb, :verified_routes

  attr :current_user, :map, required: true
  attr :page_title, :string, default: "Dashboard"
  attr :current_path, :string, default: ""
  attr :flash, :map, default: %{}
  attr :features_version, :integer, default: 0
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

    assigns =
      assigns
      |> assign(:app_version, app_version)
      |> assign(:nav_sections, nav_sections)
      |> assign(:nav_section_ids, Enum.map(nav_sections, & &1.id))

    ~H"""
    <div class="min-h-screen flex bg-[#f0f4f8]" id="bo-root">
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

                #header-user-menu > summary {
                  list-style: none;
                }
                #header-user-menu > summary::-webkit-details-marker {
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
            background: #2c3a50;
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
                  background: #1e2a3a;
                  color: white;
                  font-size: 0.72rem;
                  font-family: monospace;
                  padding: 4px 10px;
                  border-radius: 6px;
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
                  background: rgba(3, 182, 212, 0.12);
                  border-left: 2px solid #03b6d4;
                  border-radius: 6px;
                }
                #bo-sidebar.collapsed button.active-section {
                  background: transparent;
                  border-left: none;
                }

                /* Open but inactive section — gray tint */
                .open-section-wrap {
                  background: rgba(255, 255, 255, 0.04);
                  border-left: 2px solid rgba(255, 255, 255, 0.08);
                  border-radius: 6px;
                }

                /* Collapsed non-active section: gray tint when open */
                #bo-sidebar.collapsed .section-open:not(.active-section-wrap) {
                  background: rgba(255, 255, 255, 0.06);
                  border-left: 2px solid rgba(255, 255, 255, 0.12);
                  border-radius: 6px;
                }
                #bo-sidebar.collapsed .section-open:not(.active-section-wrap) button {
                  background: transparent;
                }
      </style>
      
    <!-- Sidebar -->
      <aside
        id="bo-sidebar"
        data-section-ids={Enum.join(@nav_section_ids, ",")}
        class="fixed top-0 left-0 h-screen bg-[#2c3a50] flex flex-col z-40 shadow-xl"
      >
        
    <!-- Logo + collapse toggle -->
        <div class="h-16 flex items-center justify-between px-3 border-b border-white/10 flex-shrink-0">
          <div class="flex items-center gap-2 min-w-0">
            <img
              src={~p"/images/zaq.png"}
              alt="ZAQ Logo"
              class="sidebar-logo h-8 w-8 flex-shrink-0 rounded-lg object-contain"
            />
            <span class="logo-text font-mono text-[0.65rem] text-white/40 tracking-widest uppercase whitespace-nowrap transition-all duration-200">
              Back Office
            </span>
          </div>
          <button
            id="sidebar-toggle"
            onclick="toggleSidebar()"
            class="flex-shrink-0 w-7 h-7 rounded-md flex items-center justify-center text-white/30 hover:text-white hover:bg-white/10 transition-all"
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
                "flex items-center gap-3 px-2.5 py-2.5 rounded-lg font-mono text-[0.82rem] transition-all",
                if(String.starts_with?(@current_path, "/bo/dashboard"),
                  do: "bg-[#03b6d4] text-white shadow-sm",
                  else: "text-white/60 hover:text-white hover:bg-white/8"
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
              <span class="nav-label transition-all duration-200 whitespace-nowrap">Dashboard</span>
            </a>
            <div class="nav-tooltip">Dashboard</div>
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

        <div class="border-t border-white/10 p-3 flex-shrink-0 space-y-3">
          <a
            id="sidebar-github-link"
            href="https://github.com/www-zaq-ai/zaq"
            target="_blank"
            rel="noreferrer"
            class="group flex items-start gap-2.5 rounded-lg px-2 py-2 text-white/70 hover:text-white hover:bg-white/10 transition-colors"
          >
            <svg
              class="w-5 h-5 flex-shrink-0 text-white/70 group-hover:text-white transition-colors"
              viewBox="0 0 24 24"
              fill="currentColor"
              aria-hidden="true"
            >
              <path d="M12 .5C5.65.5.5 5.65.5 12c0 5.09 3.3 9.41 7.88 10.94.58.11.79-.25.79-.56 0-.28-.01-1.02-.01-2-3.2.7-3.87-1.54-3.87-1.54-.53-1.34-1.28-1.69-1.28-1.69-1.05-.72.08-.71.08-.71 1.16.08 1.77 1.2 1.77 1.2 1.03 1.77 2.71 1.26 3.37.97.1-.75.4-1.26.72-1.55-2.55-.29-5.23-1.28-5.23-5.68 0-1.26.45-2.29 1.19-3.1-.12-.3-.52-1.5.11-3.13 0 0 .97-.31 3.19 1.18A11.08 11.08 0 0 1 12 6.1c.98 0 1.97.13 2.9.39 2.22-1.49 3.19-1.18 3.19-1.18.64 1.63.24 2.83.12 3.13.74.81 1.19 1.84 1.19 3.1 0 4.41-2.68 5.39-5.24 5.68.41.35.77 1.03.77 2.08 0 1.51-.01 2.73-.01 3.1 0 .31.21.68.8.56A11.5 11.5 0 0 0 23.5 12C23.5 5.65 18.35.5 12 .5Z" />
            </svg>
            <div class="sidebar-github-copy min-w-0 transition-all duration-200">
              <p class="font-mono text-[0.72rem] tracking-wide leading-tight">Star Zaq on GitHub</p>
              <p class="font-mono text-[0.62rem] text-white/45 mt-0.5 leading-tight">
                Follow updates and support the project
              </p>
            </div>
          </a>
          <div class="flex items-center justify-end">
            <span class="sidebar-version font-mono text-[0.65rem] text-white/40">
              v{@app_version}
            </span>
          </div>
        </div>
      </aside>
      
    <!-- Main -->
      <main id="bo-main" class="flex-1">
        <!-- Header -->
        <header class="h-16 bg-white border-b border-black/10 flex items-center justify-between px-8 shadow-sm">
          <h1 class="font-mono text-lg font-bold text-[#2c3a50]">{@page_title}</h1>

          <details id="header-user-menu" class="relative">
            <summary
              id="header-user-trigger"
              class="list-none flex items-center gap-2 rounded-lg border border-black/10 px-2 py-1.5 cursor-pointer hover:bg-black/[0.03] transition-colors"
            >
              <span class="w-8 h-8 rounded-lg bg-[#03b6d4]/15 grid place-items-center text-xs font-bold font-mono text-[#03b6d4] border border-[#03b6d4]/20">
                {String.first(@current_user.username) |> String.upcase()}
              </span>
              <span class="font-mono text-[0.72rem] text-[#2c3a50]/80">{@current_user.username}</span>
            </summary>

            <div
              id="header-user-dropdown"
              class="absolute right-0 top-[calc(100%+0.55rem)] w-56 rounded-xl border border-black/10 bg-white shadow-xl p-1.5 z-50"
            >
              <a
                id="header-profile-link"
                href={~p"/bo/profile"}
                class="block rounded-lg px-3 py-2 font-mono text-[0.72rem] text-[#2c3a50] hover:bg-black/[0.04]"
              >
                Profile
              </a>
              <div class="my-1 h-px bg-black/10" />
              <a
                id="header-system-config-link"
                href={~p"/bo/system-config"}
                class="block rounded-lg px-3 py-2 font-mono text-[0.72rem] text-[#2c3a50] hover:bg-black/[0.04]"
              >
                System config
              </a>
              <a
                id="header-system-license-link"
                href={~p"/bo/license"}
                class="block rounded-lg px-3 py-2 font-mono text-[0.72rem] text-[#2c3a50] hover:bg-black/[0.04]"
              >
                System License
              </a>
              <div class="my-1 h-px bg-black/10" />
              <form id="header-logout-form" method="post" action={~p"/bo/session"}>
                <input type="hidden" name="_method" value="delete" />
                <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
                <button
                  id="header-logout-button"
                  type="submit"
                  class="w-full text-left rounded-lg px-3 py-2 font-mono text-[0.72rem] text-red-600 hover:bg-red-50"
                >
                  Logout
                </button>
              </form>
            </div>
          </details>
        </header>
        <!-- Content -->
        <div class="p-8">
          <div
            :if={Phoenix.Flash.get(@flash, :info)}
            class="mb-4 rounded-xl bg-emerald-100 border border-emerald-200 text-emerald-700 text-sm px-4 py-3 flex items-center gap-2 font-mono"
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
            <span>{Phoenix.Flash.get(@flash, :info)}</span>
          </div>
          <div
            :if={Phoenix.Flash.get(@flash, :error)}
            class="mb-4 rounded-xl bg-red-100 border border-red-200 text-red-600 text-sm px-4 py-3 flex items-center gap-2 font-mono"
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
            <span>{Phoenix.Flash.get(@flash, :error)}</span>
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
        if(@active, do: "active-section-wrap", else: if(@open, do: "open-section-wrap", else: ""))
      ]}
      id={@id}
    >
      <%!-- Section header / toggle --%>
      <button
        onclick={"toggleSection('#{@id}')"}
        class={[
          "w-full flex items-center justify-between px-2.5 py-1.5 rounded-lg transition-all group",
          if(@active,
            do: "active-section bg-[#03b6d4]/15 text-[#03b6d4] hover:bg-[#03b6d4]/25",
            else: "text-amber-400/80 hover:text-amber-300 hover:bg-white/5"
          )
        ]}
      >
        <div class="flex items-center gap-2.5 min-w-0">
          <%!-- Section Icon --%>
          <.section_icon icon={@icon} active={@active} />
          <span class="section-label font-mono text-[0.58rem] uppercase tracking-widest transition-all duration-200 whitespace-nowrap inherit">
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
                "flex items-center gap-3 px-2.5 py-2 rounded-lg font-mono text-[0.82rem] transition-all",
                if(Map.get(item, :locked),
                  do: "text-white/25 hover:text-white/40 hover:bg-white/5 cursor-default",
                  else:
                    if(item.active,
                      do: "bg-[#03b6d4] text-white shadow-sm",
                      else: "text-white/55 hover:text-white hover:bg-white/8"
                    )
                )
              ]}
            >
              <.nav_icon icon={item.icon} />
              <span class="nav-label transition-all duration-200 whitespace-nowrap flex-1">
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
            <div class="nav-tooltip">{item.label}</div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp section_icon(assigns) do
    icon_class =
      if assigns.active,
        do: "w-4 h-4 flex-shrink-0 text-[#03b6d4] transition-colors",
        else:
          "w-4 h-4 flex-shrink-0 text-amber-400/80 group-hover:text-amber-300 transition-colors"

    assigns = assign(assigns, :icon_class, icon_class)

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
            <div class="bg-[#2c3a50] text-white font-mono text-[0.65rem] px-2.5 py-1.5 rounded-lg whitespace-nowrap shadow-lg">
              {@hint}
            </div>
            <div class="w-0 h-0 border-l-4 border-r-4 border-t-4 border-l-transparent border-r-transparent border-t-[#2c3a50] mx-auto" />
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
  Renders a centered "feature not licensed" gate card.

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
          "The #{String.downcase(assigns.feature_name)} feature is not included in your current license. Contact your administrator."

        msg ->
          msg
      end)

    ~H"""
    <div class="flex items-center justify-center min-h-[60vh]">
      <div class="bg-white rounded-xl border border-dashed border-black/15 p-10 text-center max-w-md">
        <div class="w-10 h-10 rounded-lg bg-red-100 grid place-items-center mx-auto mb-4">
          <svg
            class="w-5 h-5 text-red-500"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            viewBox="0 0 24 24"
          >
            <path d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126z" />
            <path d="M12 15.75h.007v.008H12v-.008z" />
          </svg>
        </div>
        <p class="font-mono text-sm font-bold text-black mb-1">Feature Not Licensed</p>
        <p class="font-mono text-[0.7rem] text-black/40 mb-5">{@message}</p>
        <.link
          href={~p"/bo/license"}
          class="inline-block font-mono text-[0.8rem] font-bold px-5 py-2.5 rounded-lg bg-[#3c4b64] text-white hover:bg-[#3c4b64]/90 transition-colors"
        >
          View License
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
            href: ~p"/bo/ai-diagnostics",
            icon: "ai",
            label: "Diagnostics",
            active: current_path == "/bo/ai-diagnostics"
          },
          %{
            href: ~p"/bo/prompt-templates",
            icon: "prompt",
            label: "Prompt Templates",
            active: current_path == "/bo/prompt-templates"
          },
          %{
            href: ~p"/bo/ingestion",
            icon: "ingestion",
            label: "Ingestion",
            active: current_path == "/bo/ingestion"
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
            href: ~p"/bo/channels",
            icon: "channels",
            label: "Channels",
            active: current_path == "/bo/channels"
          },
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
      },
      %{
        id: "section-accounts",
        label: "Accounts",
        icon: "accounts",
        active: accounts_section_active?(current_path),
        open: accounts_section_active?(current_path),
        items: [
          %{
            href: ~p"/bo/users",
            icon: "users",
            label: "Users",
            active: String.starts_with?(current_path, "/bo/users")
          },
          %{
            href: ~p"/bo/roles",
            icon: "roles",
            label: "Roles",
            active: String.starts_with?(current_path, "/bo/roles")
          }
        ]
      },
      %{
        id: "section-system",
        label: "System",
        icon: "system",
        active: system_section_active?(current_path),
        open: system_section_active?(current_path),
        items: [
          %{
            href: ~p"/bo/people",
            icon: "people",
            label: "People",
            active: String.starts_with?(current_path, "/bo/people")
          }
        ]
      }
    ]
  end

  defp ai_section_active?(current_path) do
    String.starts_with?(current_path, "/bo/ai") or
      String.starts_with?(current_path, "/bo/prompt") or
      String.starts_with?(current_path, "/bo/ingestion") or
      String.starts_with?(current_path, "/bo/ontology") or
      current_path == "/bo/knowledge-gap"
  end

  defp communication_section_active?(current_path) do
    String.starts_with?(current_path, "/bo/channels") or
      current_path in ["/bo/chat", "/bo/history"]
  end

  defp accounts_section_active?(current_path) do
    String.starts_with?(current_path, "/bo/users") or
      String.starts_with?(current_path, "/bo/roles")
  end

  defp system_section_active?(current_path) do
    String.starts_with?(current_path, "/bo/people")
  end
end
