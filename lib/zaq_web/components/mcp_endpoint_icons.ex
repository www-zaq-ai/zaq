defmodule ZaqWeb.Components.MCPEndpointIcons do
  @moduledoc """
  SVG icon components for predefined MCP endpoints.
  """
  use Phoenix.Component

  attr :endpoint_key, :string, default: nil
  attr :class, :string, default: "w-4 h-4"

  def icon(assigns) do
    ~H"""
    <%= case @endpoint_key do %>
      <% "github_mcp" -> %>
        <svg class={@class} viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" fill="none">
          <rect x="2" y="2" width="20" height="20" rx="6" fill="#111827" />
          <path
            d="M12 6.2c-3.2 0-5.8 2.6-5.8 5.8 0 2.5 1.6 4.7 3.9 5.4.3.1.4-.1.4-.3v-1.1c-1.6.4-1.9-.7-1.9-.7-.3-.7-.7-.9-.7-.9-.6-.4 0-.4 0-.4.7 0 1 .7 1 .7.6 1 1.6.7 2 .5.1-.5.3-.7.5-.9-1.3-.1-2.7-.7-2.7-2.9 0-.7.2-1.2.7-1.7-.1-.2-.3-.8.1-1.7 0 0 .6-.2 1.8.7a6 6 0 0 1 3.4 0c1.3-.9 1.8-.7 1.8-.7.4.9.1 1.5.1 1.7.4.5.7 1 .7 1.7 0 2.2-1.4 2.8-2.7 2.9.3.2.5.6.5 1.2v1.8c0 .2.1.4.4.3a5.8 5.8 0 0 0 3.9-5.4c0-3.2-2.6-5.8-5.8-5.8z"
            fill="#fff"
          />
        </svg>
      <% "stripe_mcp" -> %>
        <svg class={@class} viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" fill="none">
          <rect x="2" y="2" width="20" height="20" rx="6" fill="#635BFF" />
          <path
            d="M12.5 8.1c-1.1 0-1.8.5-1.8 1.2 0 .6.4.9 1.5 1.1 1.7.4 2.8 1 2.8 2.6 0 1.8-1.4 3-3.5 3-1 0-2-.2-2.8-.7v-1.8c.8.5 1.8.8 2.8.8 1.1 0 1.8-.4 1.8-1.1 0-.6-.4-.9-1.6-1.2-1.7-.4-2.7-1-2.7-2.6 0-1.8 1.4-2.9 3.4-2.9.9 0 1.8.2 2.5.6v1.7c-.8-.4-1.6-.7-2.4-.7z"
            fill="#fff"
          />
        </svg>
      <% "context_awesome_mcp" -> %>
        <svg class={@class} xmlns="http://www.w3.org/2000/svg" viewBox="0 0 585 300" fill="none">
          <path
            fill="#FC60A8"
            d="M585 38 435-99.6l-21.1 23L539 38H46l125-114.7-21.1-23L0 38v90.7c0 41 39.5 74.4 88 74.4h92.5c48.5 0 88-33.4 88-74.4V69h48v59.6c0 41 39.5 74.4 88 74.4H497c48.5 0 88-33.4 88-74.4V38z"
          />
        </svg>
      <% "datagouv_mcp" -> %>
        <svg class={@class} viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" fill="none">
          <g transform="translate(3 3)">
            <g transform="translate(3 0)">
              <polygon points="6,0.6 9,2.3 6,4 3,2.3" fill="#1D4ED8" />
              <polygon points="3,2.3 6,4 6,7.5 3,5.8" fill="#2563EB" />
              <polygon points="9,2.3 6,4 6,7.5 9,5.8" fill="#1E40AF" />
            </g>

            <g transform="translate(0 5.2)">
              <polygon points="6,0.6 9,2.3 6,4 3,2.3" fill="#1D4ED8" />
              <polygon points="3,2.3 6,4 6,7.5 3,5.8" fill="#2563EB" />
              <polygon points="9,2.3 6,4 6,7.5 9,5.8" fill="#1E40AF" />
            </g>

            <g transform="translate(6 5.2)">
              <polygon points="6,0.6 9,2.3 6,4 3,2.3" fill="#1D4ED8" />
              <polygon points="3,2.3 6,4 6,7.5 3,5.8" fill="#2563EB" />
              <polygon points="9,2.3 6,4 6,7.5 9,5.8" fill="#1E40AF" />
            </g>
          </g>
        </svg>
      <% "tweetsave_mcp" -> %>
        <svg class={@class} viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" fill="none">
          <rect x="2" y="2" width="20" height="20" rx="6" fill="#0F172A" />
          <path
            d="M17.2 8.5c-.4.2-.8.3-1.2.3.4-.2.7-.6.9-1-.4.2-.9.4-1.3.5a2.1 2.1 0 0 0-3.6 1.9c-1.7-.1-3.3-.9-4.3-2.1a2.1 2.1 0 0 0 .6 2.8c-.3 0-.7-.1-1-.2 0 1 .7 1.9 1.7 2.1-.3.1-.6.1-1 .1.3.9 1.1 1.5 2.1 1.5a4.4 4.4 0 0 1-2.7.9H7a6.2 6.2 0 0 0 3.4 1c4.1 0 6.4-3.4 6.4-6.4v-.3c.4-.3.7-.6 1-.9z"
            fill="#38BDF8"
          />
        </svg>
      <% _ -> %>
        <svg class={@class} viewBox="0 0 24 24" xmlns="http://www.w3.org/2000/svg" fill="none">
          <rect x="2" y="2" width="20" height="20" rx="6" fill="#E5E7EB" />
          <path d="M7 12h10M12 7v10" stroke="#6B7280" stroke-width="1.8" stroke-linecap="round" />
        </svg>
    <% end %>
    """
  end
end
