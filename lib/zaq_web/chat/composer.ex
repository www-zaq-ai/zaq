defmodule ZaqWeb.Chat.Composer do
  @moduledoc """
  BO Chat — filter chips, @-autocomplete, textarea, and send control.
  """

  use Phoenix.Component

  @busy_statuses [:validating, :thinking, :retrieving, :answering, :tool_call, :mcp_call]

  attr :active_filters, :list, required: true
  attr :filter_suggestions, :list, required: true
  attr :input_value, :string, required: true
  attr :status, :atom, required: true

  def composer(assigns) do
    assigns = assign(assigns, :busy_statuses, @busy_statuses)

    ~H"""
    <div class="flex-shrink-0 border-t border-[#e8e6e1] bg-white px-6 py-3.5">
      <div class="max-w-3xl mx-auto">
        <div :if={@active_filters != []} class="flex flex-wrap gap-1.5 mb-2">
          <span
            class="font-mono text-[0.6rem] uppercase tracking-widest self-center"
            style="color:#b8b5ae;"
          >
            Filtering
          </span>
          <button
            :for={filter <- @active_filters}
            phx-click="remove_content_filter"
            phx-value-source_prefix={filter.source_prefix}
            class="flex items-center gap-1 px-2 py-0.5 rounded-full text-[0.72rem] font-mono transition-all hover:opacity-80"
            style="background:#e8f7fb; color:#03b6d4; border: 1px solid #b3e8f3;"
            title={"Remove filter: #{filter.source_prefix}"}
          >
            <svg
              class="w-3 h-3 flex-shrink-0"
              fill="none"
              stroke="currentColor"
              stroke-width="2"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
              />
            </svg>
            {filter.label}
            <svg
              class="w-2.5 h-2.5 flex-shrink-0"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              viewBox="0 0 24 24"
            >
              <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
            </svg>
          </button>
        </div>

        <form id="chat-form" phx-submit="send_message" class="flex gap-3 items-center">
          <div id="content-filter-wrapper" class="flex-1 relative" phx-hook="ContentFilter">
            <div
              :if={@filter_suggestions != []}
              class="absolute bottom-full mb-1 left-0 right-0 bg-white border border-[#e0ddd8] rounded-xl shadow-lg z-20 overflow-y-auto"
              style="max-height: 240px;"
            >
              <%= for {connector, suggestions} <- Enum.group_by(@filter_suggestions, & &1.connector) do %>
                <div class="px-3 pt-2 pb-1 flex items-center gap-1.5 sticky top-0 bg-white border-b border-[#f0ede8]">
                  <svg
                    class="w-3 h-3 flex-shrink-0"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    viewBox="0 0 24 24"
                    style="color:#9e9b94;"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
                    />
                  </svg>
                  <span
                    class="font-mono text-[0.6rem] uppercase tracking-widest"
                    style="color:#9e9b94;"
                  >
                    {connector}
                  </span>
                </div>
                <div
                  :for={s <- suggestions}
                  data-suggestion-item="true"
                  data-source-prefix={s.source_prefix}
                  data-connector={s.connector}
                  data-label={s.label}
                  data-type={s.type}
                  class={[
                    "group w-full flex items-center gap-2 px-4 py-2 text-[0.8rem] hover:bg-[#f0f9fb] transition-colors cursor-pointer",
                    if(s.type == :current_folder,
                      do: "border-b border-[#f0ede8]",
                      else: ""
                    )
                  ]}
                  style="color:#3b3935;"
                >
                  <%= cond do %>
                    <% s.type == :current_folder -> %>
                      <svg
                        class="w-3.5 h-3.5 flex-shrink-0"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2"
                        viewBox="0 0 24 24"
                        style="color:#03b6d4;"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
                        />
                      </svg>
                      <span class="font-mono flex-1" style="color:#03b6d4;">
                        Use "{s.label}" folder
                      </span>
                      <svg
                        class="w-3.5 h-3.5 flex-shrink-0"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2"
                        viewBox="0 0 24 24"
                        style="color:#03b6d4;"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          d="M5 13l4 4L19 7"
                        />
                      </svg>
                    <% s.type == :file -> %>
                      <svg
                        class="w-3.5 h-3.5 flex-shrink-0"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2"
                        viewBox="0 0 24 24"
                        style="color:#9e9b94;"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                        />
                      </svg>
                      <span class="font-mono truncate flex-1">{s.label}</span>
                    <% true -> %>
                      <svg
                        class="w-3.5 h-3.5 flex-shrink-0"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2"
                        viewBox="0 0 24 24"
                        style="color:#9e9b94;"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
                        />
                      </svg>
                      <span class="font-mono truncate flex-1">{s.label}</span>
                      <button
                        type="button"
                        data-select-folder-item="true"
                        data-source-prefix={s.source_prefix}
                        data-connector={s.connector}
                        data-label={s.label}
                        data-type={s.type}
                        tabindex="-1"
                        title={"Filter by #{s.label} folder"}
                        class="opacity-0 group-hover:opacity-100 flex items-center gap-1 px-2 py-0.5 rounded-md font-mono text-[0.65rem] transition-all hover:bg-[#e8f7fb] hover:text-[#03b6d4]"
                        style="color:#9e9b94;"
                      >
                        <svg
                          class="w-3 h-3"
                          fill="none"
                          stroke="currentColor"
                          stroke-width="2"
                          viewBox="0 0 24 24"
                        >
                          <path
                            stroke-linecap="round"
                            stroke-linejoin="round"
                            d="M5 13l4 4L19 7"
                          />
                        </svg>
                        Select
                      </button>
                      <svg
                        class="w-3 h-3 flex-shrink-0"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2.5"
                        viewBox="0 0 24 24"
                        style="color:#c8c5be;"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          d="M9 5l7 7-7 7"
                        />
                      </svg>
                  <% end %>
                </div>
              <% end %>
            </div>

            <textarea
              name="message"
              id="chat-input"
              rows="1"
              phx-change="update_input"
              phx-hook="AutoExpand"
              autocomplete="off"
              placeholder="Ask a question… Type @ to filter by source  (Enter ↵ send · Shift+Enter new line)"
              disabled={@status in @busy_statuses}
              class={[
                "w-full text-[0.85rem] rounded-xl border px-4 py-2.5 resize-none overflow-hidden leading-relaxed",
                "focus:outline-none focus:ring-2 transition-all duration-200",
                if(@status in @busy_statuses, do: "cursor-not-allowed", else: "")
              ]}
              style={
                if @status in @busy_statuses,
                  do: "background:#faf9f7; border-color:#e8e6e1; color:#b8b5ae;",
                  else: "background:#ffffff; border-color:#e0ddd8; color:#2c2b28;"
              }
            ><%= @input_value %></textarea>
          </div>
          <button
            type="submit"
            disabled={@status in @busy_statuses or @input_value == ""}
            class="flex-shrink-0 w-10 h-10 rounded-xl grid place-items-center transition-all duration-200"
            style={
              if @status in @busy_statuses or @input_value == "",
                do: "background:#f0ede8; color:#c8c5be; cursor:not-allowed;",
                else: "background:#03b6d4; color:white; box-shadow:0 2px 8px rgba(3,182,212,0.25);"
            }
          >
            <svg
              class="w-4 h-4"
              fill="none"
              stroke="currentColor"
              stroke-width="2.5"
              viewBox="0 0 24 24"
            >
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                d="M6 12L3.269 3.126A59.768 59.768 0 0121.485 12 59.77 59.77 0 013.27 20.876L5.999 12zm0 0h7.5"
              />
            </svg>
          </button>
        </form>
      </div>
    </div>
    """
  end
end
