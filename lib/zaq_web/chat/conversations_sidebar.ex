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
    <aside class="w-56 flex-shrink-0 flex flex-col border-r border-[#e8e6e1] bg-white overflow-hidden">
      <div class="flex items-center justify-between px-4 py-3 border-b border-[#e8e6e1]">
        <span class="font-mono text-[0.65rem] uppercase tracking-widest" style="color:#b8b5ae;">
          My Chats
        </span>
        <button
          id="new-chat-button"
          phx-click="new_chat"
          class="flex items-center gap-1 font-mono text-[0.65rem] px-2 py-1 rounded-lg text-[#03b6d4] hover:bg-[#f0f9fb] transition-colors"
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
        <div :if={@conversations == []} class="px-4 py-6 text-center">
          <p class="font-mono text-[0.68rem]" style="color:#c8c5be;">No conversations yet.</p>
        </div>
        <%= for item <- inject_relative_date_separators(@conversations) do %>
          <%= if Map.get(item, :type) == :date_separator do %>
            <div class="px-4 pt-3 pb-1">
              <span
                class="font-mono text-[0.58rem] uppercase tracking-widest"
                style={
                  case item.label do
                    "Today" -> "color:#03b6d4;"
                    "Yesterday" -> "color:#7ecfdf;"
                    _ -> "color:#c8c5be;"
                  end
                }
              >
                {item.label}
              </span>
            </div>
          <% else %>
            <button
              phx-click="load_conversation"
              phx-value-id={item.id}
              class={[
                "w-full text-left block px-4 py-3 border-b border-[#f0ede8] transition-colors group",
                if(@current_conversation_id == item.id,
                  do: "bg-[#f0f9fb]",
                  else: "hover:bg-[#faf9f7]"
                )
              ]}
            >
              <p class={[
                "font-mono text-[0.75rem] truncate leading-snug transition-colors",
                if(@current_conversation_id == item.id,
                  do: "text-[#03b6d4]",
                  else: "text-[#2c2b28] group-hover:text-[#03b6d4]"
                )
              ]}>
                {item.title || "(untitled)"}
              </p>
              <div class="flex items-center gap-1.5 mt-0.5">
                <span class="font-mono text-[0.6rem]" style="color:#b8b5ae;">
                  {item.channel_type}
                </span>
                <span style="color:#d1cfc9;">·</span>
                <span class="font-mono text-[0.6rem]" style="color:#b8b5ae;">
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
end
