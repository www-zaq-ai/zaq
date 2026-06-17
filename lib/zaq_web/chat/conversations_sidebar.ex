defmodule ZaqWeb.Chat.ConversationsSidebar do
  @moduledoc """
  BO Chat — conversation list and "new chat" control (extracted from `ChatLive`).
  """

  use Phoenix.Component

  import ZaqWeb.Helpers.DateFormat, only: [format_time: 1, inject_relative_date_separators: 1]

  attr :conversations, :list, required: true
  attr :current_conversation_id, :any, default: nil

  def conversations_sidebar(assigns) do
    ~H"""
    <aside class="zaq-chat-conversations-sidebar">
      <div class="zaq-chat-header-bar">
        <span
          class="zaq-text-caption uppercase tracking-widest"
          style="color: var(--zaq-text-color-body-tertiary);"
        >
          My Chats
        </span>
        <button
          id="new-chat-button"
          phx-click="new_chat"
          class="zaq-btn zaq-btn-ghost zaq-btn-text_label-default flex items-center gap-1 px-2 py-1"
          title="New chat"
        >
          <svg
            class="w-3 h-3"
            fill="none"
            stroke="currentColor"
            stroke-width="2.5"
            viewBox="0 0 24 24"
          >
            <path stroke-linecap="round" stroke-linejoin="round" d="M12 4v16m8-8H4" />
          </svg>
          New
        </button>
      </div>
      <div class="flex-1 overflow-y-auto">
        <div :if={@conversations == []} class="zaq-chat-conversations-sidebar__empty">
          <p class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
            No conversations yet.
          </p>
        </div>
        <%= for item <- inject_relative_date_separators(@conversations) do %>
          <%= if Map.get(item, :type) == :date_separator do %>
            <div class="px-4 pt-3 pb-1">
              <span
                class="zaq-text-caption tracking-widest"
                style={date_separator_span_style(item.label)}
              >
                {item.label}
              </span>
            </div>
          <% else %>
            <button
              phx-click="load_conversation"
              phx-value-id={item.id}
              class="zaq-chat-conversations-sidebar__row transition-colors"
              aria-current={if(@current_conversation_id == item.id, do: "page")}
            >
              <p class="zaq-text-body-sm truncate leading-snug">
                {item.title || "(untitled)"}
              </p>
              <div
                class="flex items-center gap-1.5 mt-0.5"
                style="color: var(--zaq-text-color-body-tertiary);"
              >
                <span class="zaq-text-caption">
                  {item.channel_type}
                </span>
                <span class="zaq-text-caption" style="opacity: 0.65;">·</span>
                <span class="zaq-text-caption">
                  {format_time(item.inserted_at)}
                </span>
              </div>
            </button>
          <% end %>
        <% end %>
      </div>
    </aside>
    """
  end

  defp date_separator_span_style("Today"),
    do: "text-transform: uppercase; color: var(--zaq-text-color-body-accent);"

  defp date_separator_span_style("Yesterday"),
    do: "text-transform: uppercase; color: var(--zaq-text-color-body-secondary);"

  defp date_separator_span_style(_),
    do: "text-transform: uppercase; color: var(--zaq-text-color-body-tertiary);"
end
