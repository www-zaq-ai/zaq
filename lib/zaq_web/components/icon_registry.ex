defmodule ZaqWeb.Components.IconRegistry do
  @moduledoc false

  use Phoenix.Component

  attr :namespace, :string, required: true
  attr :name, :string, required: true
  attr :class, :string, default: "w-6 h-6"

  def icon(assigns) do
    ~H"""
    <%= case {@namespace, @name} do %>
      <% {"section", "ai"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M9.75 17L9 20l-1 1h8l-1-1-.75-3M3 13h18M5 17h14a2 2 0 002-2V5a2 2 0 00-2-2H5a2 2 0 00-2 2v10a2 2 0 002 2z"
          />
        </svg>
      <% {"section", "communication"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M8 10h.01M12 10h.01M16 10h.01M9 16H5a2 2 0 01-2-2V6a2 2 0 012-2h14a2 2 0 012 2v8a2 2 0 01-2 2h-5l-5 5v-5z"
          />
        </svg>
      <% {"section", "accounts"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M12 4.354a4 4 0 110 5.292M15 21H3v-1a6 6 0 0112 0v1zm0 0h6v-1a6 6 0 00-9-5.197M13 7a4 4 0 11-8 0 4 4 0 018 0z"
          />
        </svg>
      <% {"section", "system"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.065 2.572c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.572 1.065c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.065-2.572c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z"
          />
          <path stroke-linecap="round" stroke-linejoin="round" d="M15 12a3 3 0 11-6 0 3 3 0 016 0z" />
        </svg>
      <% {"nav", "dashboard"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
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
      <% {"nav", "ai"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path d="M12 2a4 4 0 0 1 4 4v1h1a3 3 0 0 1 0 6h-1v1a4 4 0 0 1-8 0v-1H7a3 3 0 0 1 0-6h1V6a4 4 0 0 1 4-4z" />
          <circle cx="9" cy="10" r="1" fill="currentColor" stroke="none" />
          <circle cx="15" cy="10" r="1" fill="currentColor" stroke="none" />
        </svg>
      <% {"nav", "prompt"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
        </svg>
      <% {"nav", "ingestion"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path d="M21 15v4a2 2 0 01-2 2H5a2 2 0 01-2-2v-4" />
          <polyline points="7 10 12 15 17 10" />
          <line x1="12" y1="15" x2="12" y2="3" />
        </svg>
      <% {"nav", "ontology"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="3" /><path d="M12 2v4" /><path d="M12 18v4" />
          <path d="M4.93 4.93l2.83 2.83" /><path d="M16.24 16.24l2.83 2.83" />
          <path d="M2 12h4" /><path d="M18 12h4" />
          <path d="M4.93 19.07l2.83-2.83" /><path d="M16.24 7.76l2.83-2.83" />
        </svg>
      <% {"nav", "knowledge_gap"} -> %>
        <svg
          class={@class}
          fill="none"
          stroke="currentColor"
          stroke-width="1.8"
          viewBox="0 0 24 24"
          stroke-linecap="round"
          stroke-linejoin="round"
        >
          <line x1="12" y1="3" x2="12" y2="21" />
          <path d="M12 3 L4 5 L4 21 L12 21" />
          <path d="M12 3 L20 5 L20 21 L12 21" stroke-dasharray="3 2" />
          <line x1="6" y1="9" x2="10" y2="9" />
          <line x1="6" y1="12" x2="10" y2="12" />
          <path d="M15 8 Q15 6 16.5 6 Q18 6 18 8 Q18 10 16.5 10.5" />
          <circle cx="16.5" cy="13" r="0.6" fill="currentColor" stroke="none" />
          <line x1="16.5" y1="1" x2="16.5" y2="4" />
          <polyline points="15,3 16.5,4.5 18,3" />
        </svg>
      <% {"nav", "channels"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path d="M3 6h18M3 12h18M3 18h18" />
          <circle cx="8" cy="6" r="1.5" fill="currentColor" />
          <circle cx="16" cy="12" r="1.5" fill="currentColor" />
          <circle cx="12" cy="18" r="1.5" fill="currentColor" />
        </svg>
      <% {"nav", "history"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10" /><polyline points="12 6 12 12 16 14" />
        </svg>
      <% {"nav", "users"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path d="M17 21v-2a4 4 0 0 0-4-4H5a4 4 0 0 0-4 4v2" /><circle cx="9" cy="7" r="4" />
          <path d="M23 21v-2a4 4 0 0 0-3-3.87" /><path d="M16 3.13a4 4 0 0 1 0 7.75" />
        </svg>
      <% {"nav", "people"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <circle cx="9" cy="7" r="4" />
          <path d="M3 21v-2a4 4 0 0 1 4-4h4a4 4 0 0 1 4 4v2" />
          <line x1="19" y1="8" x2="19" y2="14" />
          <line x1="16" y1="11" x2="22" y2="11" />
        </svg>
      <% {"nav", "roles"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path d="M12 22s8-4 8-10V5l-8-3-8 3v7c0 6 8 10 8 10z" />
        </svg>
      <% {"nav", "license"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <rect x="3" y="11" width="18" height="11" rx="2" ry="2" />
          <path d="M7 11V7a5 5 0 0 1 10 0v4" />
        </svg>
      <% {"nav", "conversations"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" />
          <line x1="9" y1="10" x2="15" y2="10" />
          <line x1="9" y1="14" x2="13" y2="14" />
        </svg>
      <% {"nav", "config"} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <path d="M12 20h9" /><path d="M16.5 3.5a2.121 2.121 0 013 3L7 19l-4 1 1-4L16.5 3.5z" />
        </svg>
      <% {"provider", "mattermost"} -> %>
        <svg class={@class} xmlns="http://www.w3.org/2000/svg" viewBox="0 0 164.3 164.3">
          <g>
            <g>
              <path
                fill="#1D325C"
                fill-rule="evenodd"
                clip-rule="evenodd"
                d="M130.4,15.7l0.9,17.4C145.4,48.7,151,70.8,144,91.6c-10.5,31-45.1,47.3-77.4,36.4S16.8,83.1,27.3,52.1c7.1-20.9,25-35.1,45.8-38.8L84.3,0c-35.1-0.9-68.1,20.8-80,55.8c-14.5,43,8.5,89.6,51.5,104.1s89.6-8.5,104.1-51.5C171.7,73.6,158.7,36.2,130.4,15.7z"
              />
            </g>
            <path
              fill="#1D325C"
              fill-rule="evenodd"
              clip-rule="evenodd"
              d="M110.3,67.1l-0.6-24.4l-0.5-14l-0.3-12.2c0,0,0.1-5.9-0.1-7.2c0-0.3-0.1-0.5-0.2-0.7V8.4c-0.2-0.4-0.6-0.7-1-0.9c-0.5-0.2-1-0.1-1.4,0.1c0,0-0.1,0-0.1,0.1c-0.2,0.1-0.4,0.2-0.6,0.4c-1,1-4.5,5.7-4.5,5.7l-7.6,9.5l-8.9,10.9l-15.3,19c0,0-7,8.7-5.5,19.5s9.6,16,15.8,18.1S95.3,93.6,103,86C110.5,78.3,110.3,67.1,110.3,67.1L110.3,67.1z"
            />
          </g>
        </svg>
      <% {"provider", _} -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10" />
          <path d="M12 8v4m0 4h.01" />
        </svg>
      <% _ -> %>
        <svg class={@class} fill="none" stroke="currentColor" stroke-width="1.8" viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="10" />
          <path d="M12 8v4m0 4h.01" />
        </svg>
    <% end %>
    """
  end
end
