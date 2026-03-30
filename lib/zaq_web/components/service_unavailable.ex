defmodule ZaqWeb.Components.ServiceUnavailable do
  @moduledoc """
  Reusable component displayed when one or more required service roles
  are not running on any connected node.

  Renders inside BOLayout so the sidebar remains visible.

  ## Usage in a LiveView template

      <ZaqWeb.Components.ServiceUnavailable.page
        current_user={@current_user}
        current_path={@current_path}
        page_title={@page_title}
        services={@required_roles}
      />

  ## Usage — check only (no render)

      ServiceUnavailable.available?([:agent, :ingestion])
      ServiceUnavailable.missing_roles([:agent, :ingestion])
  """

  use Phoenix.Component

  alias Zaq.RuntimeDeps

  defp node_router, do: RuntimeDeps.node_router()

  @supervisor_map %{
    agent: Zaq.Agent.Supervisor,
    ingestion: Zaq.Ingestion.Supervisor,
    channels: Zaq.Channels.Supervisor,
    engine: Zaq.Engine.Supervisor,
    bo: ZaqWeb.Endpoint
  }

  @role_labels %{
    agent: "Agent",
    ingestion: "Ingestion",
    channels: "Channels",
    engine: "Engine",
    bo: "Back Office"
  }

  @role_hints %{
    agent: "agent",
    ingestion: "ingestion",
    channels: "channels",
    engine: "engine",
    bo: "bo"
  }

  @doc """
  Returns true if all required services are available across connected nodes.
  """
  def available?(roles) when is_list(roles) do
    Enum.all?(roles, &role_running?/1)
  end

  @doc """
  Returns a list of roles that are not currently running on any node.
  """
  def missing_roles(roles) when is_list(roles) do
    Enum.reject(roles, &role_running?/1)
  end

  @doc """
  Renders the full service unavailable page inside BOLayout.
  Use this in templates when @service_available is false.

  ## Attributes

    * `current_user`  - passed to BOLayout
    * `current_path`  - passed to BOLayout for sidebar highlight
    * `page_title`    - passed to BOLayout header
    * `services`      - list of required role atoms
  """
  attr :current_user, :any, required: true
  attr :current_path, :string, required: true
  attr :page_title, :string, required: true
  attr :services, :list, required: true

  def page(assigns) do
    missing = missing_roles(assigns.services)
    assigns = assign(assigns, :missing, missing)

    ~H"""
    <ZaqWeb.Components.BOLayout.bo_layout
      current_user={@current_user}
      page_title={@page_title}
      current_path={@current_path}
    >
      <div class="flex flex-col items-center justify-center min-h-[60vh] px-6 text-center">
        
    <!-- Icon -->
        <div
          class="w-14 h-14 rounded-2xl grid place-items-center mb-5"
          style="background-color: rgba(3,182,212,0.08); border: 1px solid rgba(3,182,212,0.2);"
        >
          <svg
            class="w-7 h-7"
            style="color: #03b6d4;"
            fill="none"
            stroke="currentColor"
            stroke-width="1.8"
            viewBox="0 0 24 24"
          >
            <path
              stroke-linecap="round"
              stroke-linejoin="round"
              d="M12 9v3.75m-9.303 3.376c-.866 1.5.217 3.374 1.948 3.374h14.71c1.73 0 2.813-1.874 1.948-3.374L13.949 3.378c-.866-1.5-3.032-1.5-3.898 0L2.697 16.126zM12 15.75h.007v.008H12v-.008z"
            />
          </svg>
        </div>
        
    <!-- Title -->
        <h2 class="font-mono text-lg font-bold text-black mb-2">
          Service Unavailable
        </h2>
        <p class="font-mono text-sm text-black/50 mb-6 max-w-md">
          This page requires the following {if length(@missing) == 1, do: "service", else: "services"} to be running on a connected node:
        </p>
        
    <!-- Missing services list -->
        <div class="flex flex-col gap-2 mb-8 w-full max-w-2xl">
          <%= for role <- @missing do %>
            <div class="flex items-center gap-3 bg-white border border-black/10 rounded-xl px-5 py-3">
              <span
                class="w-2 h-2 rounded-full flex-shrink-0"
                style="background-color: #ef4444;"
              >
              </span>
              <span class="font-mono text-sm font-bold text-black">
                {role_label(role)}
              </span>
              <span class="font-mono text-xs text-black/40 ml-auto">not running</span>
            </div>
          <% end %>
        </div>
        
    <!-- How to fix -->
        <div class="bg-white border border-black/10 rounded-xl px-6 py-5 text-left max-w-2xl w-full">
          <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider mb-2">
            How to fix
          </p>
          <p class="font-mono text-xs text-black/50 mb-3">
            Start a node with the required {if length(@missing) == 1, do: "role", else: "roles"} and connect it using the
            <code class="px-1 rounded text-[#03b6d4]" style="background-color: rgba(3,182,212,0.08);">
              NODES
            </code>
            env var:
          </p>
          <div class="rounded-lg px-4 py-3" style="background-color: #3c4b64;">
            <code class="block font-mono text-xs text-white/80 whitespace-pre-wrap">
              {hint_command(@missing)}
            </code>
          </div>
        </div>
        
    <!-- Connected nodes -->
        <p class="font-mono text-[0.7rem] text-black/30 mt-6">
          Connected nodes:
          <%= if Node.list() == [] do %>
            none
          <% else %>
            {Enum.join(Node.list(), ", ")}
          <% end %>
        </p>
      </div>
    </ZaqWeb.Components.BOLayout.bo_layout>
    """
  end

  # -- Private --

  defp role_running?(role) do
    supervisor = Map.fetch!(@supervisor_map, role)

    case node_router().find_node(supervisor) do
      nil -> false
      n when n == node() -> Process.whereis(supervisor) != nil
      _peer -> true
    end
  end

  defp role_label(role), do: Map.get(@role_labels, role, to_string(role))

  defp hint_command(missing) do
    roles = Enum.map_join(missing, ",", &Map.get(@role_hints, &1, to_string(&1)))
    "ROLES=#{roles} iex --sname <name>@localhost \\\n  --cookie zaq_dev -S mix"
  end
end
