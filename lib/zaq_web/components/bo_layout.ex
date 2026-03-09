# lib/zaq_web/components/bo_layout.ex

defmodule ZaqWeb.Components.BOLayout do
  @moduledoc """
  This module defines a Phoenix component for the back office (BO) layout of the application. It provides a consistent structure and styling for all BO pages, including a sidebar with navigation links, a header with the page title, and a main content area where the specific page content will be rendered. The layout also includes user information and a logout button in the sidebar. The component uses Tailwind CSS for styling and is designed to be responsive and user-friendly.
  """
  use Phoenix.Component
  use ZaqWeb, :verified_routes

  attr :current_user, :map, required: true
  attr :page_title, :string, default: "Dashboard"
  attr :current_path, :string, default: ""
  slot :inner_block, required: true

  def bo_layout(assigns) do
    ~H"""
    <div class="min-h-screen flex bg-[#f5f5f5]">
      <!-- Sidebar -->
      <aside class="w-[240px] fixed top-0 left-0 h-screen bg-[#3c4b64] flex flex-col">
        <!-- Logo -->
        <div class="h-16 flex items-center px-6 border-b border-white/10">
          <image src={~p"/images/zaq.png"} alt="ZAQ Logo" class="h-12" />
          <span class="font-mono text-[0.65rem] text-white/40 ml-2 tracking-widest uppercase">
            Back Office
          </span>
        </div>
        
    <!-- Nav -->
        <nav class="flex-1 py-4 px-3 space-y-1 overflow-y-auto">
          <.nav_item
            href={~p"/bo/dashboard"}
            icon="dashboard"
            label="Dashboard"
            active={@current_path == "/bo/dashboard"}
          />
          
    <!-- AI -->
          <div class="pt-4">
            <p class="font-mono text-[0.6rem] text-white/30 uppercase tracking-widest px-3 mb-2">
              AI
            </p>
            <.nav_item
              href={~p"/bo/ai-diagnostics"}
              icon="ai"
              label="Diagnostics"
              active={@current_path == "/bo/ai-diagnostics"}
            />
            <.nav_item
              href={~p"/bo/prompt-templates"}
              icon="prompt"
              label="Prompt Templates"
              active={@current_path == "/bo/prompt-templates"}
            />
            <.nav_item
              href={~p"/bo/ingestion"}
              icon="ingestion"
              label="Ingestion"
              active={@current_path == "/bo/ingestion"}
            />

            <.nav_item
              href={~p"/bo/ontology"}
              icon="ontology"
              label="Ontology"
              active={String.starts_with?(@current_path, "/bo/ontology")}
            />
          </div>
          <!-- Communication -->
          <div class="pt-4">
            <p class="font-mono text-[0.6rem] text-white/30 uppercase tracking-widest px-3 mb-2">
              Communication
            </p>
            <.nav_item
              href={~p"/bo/channels"}
              icon="channels"
              label="Channels"
              active={@current_path == "/bo/channels"}
            />
            <.nav_item
              href={~p"/bo/playground"}
              icon="playground"
              label="Playground"
              active={@current_path == "/bo/playground"}
            />
            <.nav_item
              href={~p"/bo/history"}
              icon="history"
              label="History"
              active={@current_path == "/bo/history"}
            />
          </div>
          <!-- Accounts -->
          <div class="pt-4">
            <p class="font-mono text-[0.6rem] text-white/30 uppercase tracking-widest px-3 mb-2">
              Accounts
            </p>
            <.nav_item
              href={~p"/bo/users"}
              icon="users"
              label="Users"
              active={String.starts_with?(@current_path, "/bo/users")}
            />
            <.nav_item
              href={~p"/bo/roles"}
              icon="roles"
              label="Roles"
              active={String.starts_with?(@current_path, "/bo/roles")}
            />
          </div>
          <!-- System -->
          <div class="pt-4">
            <p class="font-mono text-[0.6rem] text-white/30 uppercase tracking-widest px-3 mb-2">
              System
            </p>
            <.nav_item
              href={~p"/bo/license"}
              icon="license"
              label="License"
              active={@current_path == "/bo/license"}
            />
          </div>
        </nav>
        
    <!-- User / Logout -->
        <div class="border-t border-white/10 p-4">
          <div class="flex items-center gap-3 mb-3">
            <div class="w-8 h-8 rounded-lg bg-[#03b6d4]/15 grid place-items-center text-xs font-bold font-mono text-[#03b6d4]">
              {String.first(@current_user.username) |> String.upcase()}
            </div>
            <div>
              <p class="font-mono text-sm text-white leading-tight">{@current_user.username}</p>
              <p class="font-mono text-[0.65rem] text-white/40">{@current_user.role.name}</p>
            </div>
          </div>
          <form method="post" action={~p"/bo/session"}>
            <input type="hidden" name="_method" value="delete" />
            <input type="hidden" name="_csrf_token" value={Phoenix.Controller.get_csrf_token()} />
            <button
              type="submit"
              class="w-full font-mono text-[0.75rem] text-white/40 hover:text-red-400 tracking-wide text-left transition-colors"
            >
              ← Logout
            </button>
          </form>
        </div>
      </aside>
      
    <!-- Main -->
      <main class="ml-[240px] flex-1">
        <!-- Header -->
        <header class="h-16 bg-white border-b border-black/10 flex items-center px-8">
          <h1 class="font-mono text-lg font-bold text-black">{@page_title}</h1>
        </header>
        
    <!-- Content -->
        <div class="p-8">
          {render_slot(@inner_block)}
        </div>
      </main>
    </div>
    """
  end

  attr :href, :string, required: true
  attr :icon, :string, required: true
  attr :label, :string, required: true
  attr :active, :boolean, default: false

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class={[
        "flex items-center gap-3 px-3 py-2.5 rounded-lg font-mono text-[0.82rem] transition-colors",
        if(@active,
          do: "bg-[#03b6d4] text-white",
          else: "text-white/60 hover:text-white hover:bg-white/5"
        )
      ]}
    >
      <svg
        :if={@icon == "dashboard"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <rect x="3" y="3" width="7" height="7" rx="1.5" /><rect
          x="14"
          y="3"
          width="7"
          height="7"
          rx="1.5"
        />
        <rect x="3" y="14" width="7" height="7" rx="1.5" /><rect
          x="14"
          y="14"
          width="7"
          height="7"
          rx="1.5"
        />
      </svg>
      <svg
        :if={@icon == "users"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" /><circle cx="9" cy="7" r="4" />
        <path d="M23 21v-2a4 4 0 0 0-3-3.87" /><path d="M16 3.13a4 4 0 0 1 0 7.75" />
      </svg>
      <svg
        :if={@icon == "roles"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
      </svg>
      <svg
        :if={@icon == "ai"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <path d="M12 2a4 4 0 0 1 4 4v1h1a3 3 0 0 1 0 6h-1v1a4 4 0 0 1-8 0v-1H7a3 3 0 0 1 0-6h1V6a4 4 0 0 1 4-4z" />
        <circle cx="9" cy="10" r="1" fill="currentColor" stroke="none" />
        <circle cx="15" cy="10" r="1" fill="currentColor" stroke="none" />
      </svg>

      <svg
        :if={@icon == "prompt"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
      </svg>

      <svg
        :if={@icon == "channels"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <path d="M3 6h18M3 12h18M3 18h18" />
        <circle cx="8" cy="6" r="1.5" fill="currentColor" />
        <circle cx="16" cy="12" r="1.5" fill="currentColor" />
        <circle cx="12" cy="18" r="1.5" fill="currentColor" />
      </svg>

      <svg
        :if={@icon == "playground"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <polygon points="5 3 19 12 5 21 5 3" />
      </svg>

      <svg
        :if={@icon == "history"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <circle cx="12" cy="12" r="10" />
        <polyline points="12 6 12 12 16 14" />
      </svg>

      <svg
        :if={@icon == "license"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <rect x="3" y="11" width="18" height="11" rx="2" ry="2" />
        <path d="M7 11V7a5 5 0 0 1 10 0v4" />
      </svg>

      <svg
        :if={@icon == "ontology"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <circle cx="12" cy="12" r="3" />
        <path d="M12 2v4" />
        <path d="M12 18v4" />
        <path d="M4.93 4.93l2.83 2.83" />
        <path d="M16.24 16.24l2.83 2.83" />
        <path d="M2 12h4" />
        <path d="M18 12h4" />
        <path d="M4.93 19.07l2.83-2.83" />
        <path d="M16.24 7.76l2.83-2.83" />
      </svg>

      <svg
        :if={@icon == "ingestion"}
        class="w-[18px] h-[18px]"
        fill="none"
        stroke="currentColor"
        stroke-width="1.8"
        viewBox="0 0 24 24"
      >
        <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4" />
        <polyline points="7 10 12 15 17 10" />
        <line x1="12" y1="15" x2="12" y2="3" />
      </svg>
      {@label}
    </a>
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
            <div class="bg-[#3c4b64] text-white font-mono text-[0.65rem] px-2.5 py-1.5 rounded-lg whitespace-nowrap shadow-lg">
              {@hint}
            </div>
            <div class="w-0 h-0 border-l-4 border-r-4 border-t-4 border-l-transparent border-r-transparent border-t-[#3c4b64] mx-auto" />
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
end
