defmodule ZaqWeb.Chat.Transcript do
  @moduledoc """
  BO Chat — scrollable transcript, date separators, bubbles, and thinking indicator.
  """

  use Phoenix.Component
  use ZaqWeb, :verified_routes

  import ZaqWeb.Helpers.DateFormat, only: [format_date: 1, inject_date_separators: 1]

  alias ZaqWeb.Live.BO.Communication.MessageHelpers

  @busy_statuses [:validating, :thinking, :retrieving, :answering, :tool_call, :mcp_call]

  attr :messages, :list, required: true
  attr :status, :atom, required: true
  attr :status_message, :string, required: true
  attr :streaming_response_active, :boolean, required: true

  def transcript(assigns) do
    assigns = assign(assigns, :busy_statuses, @busy_statuses)

    ~H"""
    <div
      id="chat-messages"
      phx-hook="ScrollBottom"
      class="flex-1 min-h-0 overflow-y-auto"
      style="background-color: var(--zaq-surface-color-base);"
    >
      <div class="max-w-3xl mx-auto px-6 py-6 space-y-5">
        <%= for item <- inject_date_separators(@messages) do %>
          <%= if Map.get(item, :type) == :date_separator do %>
            <div class="flex items-center gap-3 my-1">
              <div class="zaq-chat-transcript__date-rule"></div>
              <span
                class="zaq-text-caption uppercase tracking-widest"
                style="color: var(--zaq-text-color-body-tertiary);"
              >
                {format_date(item.date)}
              </span>
              <div class="zaq-chat-transcript__date-rule"></div>
            </div>
          <% else %>
            <%= if item.role == :user do %>
              <ZaqWeb.Components.ChatMessage.user_bubble
                content={item.body}
                timestamp={item.timestamp}
                filters={Map.get(item, :filters, [])}
              >
                <:actions>
                  <button
                    phx-click="copy_message"
                    phx-value-text={item.body}
                    class="p-1 rounded transition-all"
                    style="color: var(--zaq-text-color-body-tertiary);"
                    title="Copy"
                  >
                    <svg
                      width="13"
                      height="13"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <rect x="9" y="9" width="13" height="13" rx="2" ry="2"></rect>
                      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
                    </svg>
                  </button>
                </:actions>
              </ZaqWeb.Components.ChatMessage.user_bubble>
            <% else %>
              <ZaqWeb.Components.ChatMessage.assistant_bubble
                content={item.body}
                timestamp={item.timestamp}
                msg_id={if Map.get(item, :live, false), do: item.id, else: nil}
                confidence={item.confidence}
                sources={Map.get(item, :sources, [])}
                is_error={Map.get(item, :error, false)}
                error_type={Map.get(item, :error_type)}
                source_click_event="open_preview_modal"
              >
                <:actions>
                  <ZaqWeb.Components.ChatMessage.message_info_button
                    available={
                      MessageHelpers.message_info_available?(Map.get(item, :message_info, %{}))
                    }
                    message_id={item.id}
                    open_event="open_message_info_modal"
                  />
                  <ZaqWeb.Components.ChatMessage.copy_action_button text={item.body} />
                  <ZaqWeb.Components.ChatMessage.feedback_positive_button
                    message_id={item.id}
                    feedback={item[:feedback]}
                  />
                  <ZaqWeb.Components.ChatMessage.feedback_negative_button
                    message_id={item.id}
                    feedback={item[:feedback]}
                  />
                </:actions>
              </ZaqWeb.Components.ChatMessage.assistant_bubble>
            <% end %>
          <% end %>
        <% end %>

        <%= if @status in @busy_statuses and !@streaming_response_active do %>
          <div class="flex justify-start animate-slide-in-left">
            <div class="flex gap-3">
              <img
                src={~p"/images/zaq.png"}
                alt="ZAQ"
                class="w-7 h-7 rounded-lg object-contain mt-0.5 animate-pulse flex-shrink-0"
              />
              <div>
                <div class="mb-2 flex items-center gap-2">
                  <div class="flex gap-1">
                    <span class="zaq-chat-transcript__typing-dot animate-bounce [animation-delay:0ms]">
                    </span>
                    <span class="zaq-chat-transcript__typing-dot animate-bounce [animation-delay:150ms]">
                    </span>
                    <span class="zaq-chat-transcript__typing-dot animate-bounce [animation-delay:300ms]">
                    </span>
                  </div>
                  <span
                    class="zaq-text-body-sm"
                    style="color: var(--zaq-text-color-body-tertiary);"
                  >
                    {@status_message}
                  </span>
                </div>
                <div class="flex items-center gap-3">
                  <div
                    class="flex items-center gap-1.5 zaq-text-body-sm transition-colors"
                    style={
                      if @status in @busy_statuses,
                        do: "color: var(--zaq-text-color-body-accent);",
                        else: "color: var(--zaq-text-color-body-tertiary);"
                    }
                  >
                    <div class="w-1.5 h-1.5 shrink-0 rounded-full bg-current" /> Validating
                  </div>
                  <div
                    class="flex items-center gap-1.5 zaq-text-body-sm transition-colors"
                    style={
                      if @status in [:retrieving, :answering, :thinking, :tool_call, :mcp_call],
                        do: "color: var(--zaq-text-color-body-accent);",
                        else: "color: var(--zaq-text-color-body-tertiary);"
                    }
                  >
                    <div class="w-1.5 h-1.5 shrink-0 rounded-full bg-current" /> Retrieving
                  </div>
                  <div
                    class="flex items-center gap-1.5 zaq-text-body-sm transition-colors"
                    style={
                      if @status in [:answering, :thinking, :tool_call, :mcp_call],
                        do: "color: var(--zaq-text-color-body-accent);",
                        else: "color: var(--zaq-text-color-body-tertiary);"
                    }
                  >
                    <div class="w-1.5 h-1.5 shrink-0 rounded-full bg-current" /> Answering
                  </div>
                  <div
                    :if={@status in [:tool_call, :mcp_call]}
                    class="flex items-center gap-1.5 zaq-text-body-sm transition-colors"
                    style="color: var(--zaq-text-color-body-accent);"
                  >
                    <div class="w-1.5 h-1.5 shrink-0 rounded-full bg-current" />
                    {if @status == :mcp_call, do: "MCP", else: "Tool"}
                  </div>
                </div>
              </div>
            </div>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
