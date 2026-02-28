defmodule ZaqWeb.Components.BOLayout do
  @moduledoc """
  This module defines a Phoenix component for the back office (BO) layout of the application. It provides a consistent structure and styling for all BO pages, including a sidebar with navigation links, a header with the page title, and a main content area where the specific page content will be rendered. The layout also includes user information and a logout button in the sidebar. The component uses Tailwind CSS for styling and is designed to be responsive and user-friendly.
  """
  use Phoenix.Component
  use ZaqWeb, :verified_routes

  attr :current_user, :map, required: true
  attr :page_title, :string, default: "Dashboard"
  slot :inner_block, required: true

  def bo_layout(assigns) do
    ~H"""
    <div class="min-h-screen flex bg-[#f5f5f5]">
      <!-- Sidebar -->
      <aside class="w-[240px] fixed top-0 left-0 h-screen bg-[#3c4b64] flex flex-col">
        <!-- Logo -->
        <div class="h-16 flex items-center px-6 border-b border-white/10">
          <span class="font-mono text-lg font-bold tracking-tight text-[#03b6d4]">
            ZAQ
          </span>
          <span class="font-mono text-[0.65rem] text-white/40 ml-2 tracking-widest uppercase">
            Back Office
          </span>
        </div>
        
    <!-- Nav -->
        <nav class="flex-1 py-4 px-3 space-y-1">
          <.nav_item href={~p"/bo/dashboard"} icon="dashboard" label="Dashboard" />
          
    <!-- Accounts -->
          <div class="pt-4">
            <p class="font-mono text-[0.6rem] text-white/30 uppercase tracking-widest px-3 mb-2">
              Accounts
            </p>
            <.nav_item href={~p"/bo/users"} icon="users" label="Users" />
            <.nav_item href={~p"/bo/roles"} icon="roles" label="Roles" />
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

  defp nav_item(assigns) do
    ~H"""
    <a
      href={@href}
      class="flex items-center gap-3 px-3 py-2.5 rounded-lg font-mono text-[0.82rem] text-white/60 hover:text-white hover:bg-white/5 transition-colors"
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
      {@label}
    </a>
    """
  end
end
