defmodule ZaqWeb.Chat.Composer do
  @moduledoc """
  BO Chat — filter chips, @-autocomplete for **content sources** (`filter_suggestions`),
  textarea, and send control.

  Starter “Try asking” chips are `ZaqWeb.Chat.SuggestedPrompts`, a separate component.
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
    <div class="zaq-chat-composer-footer">
      <div class="max-w-3xl mx-auto">
        <div :if={@active_filters != []} class="flex flex-wrap gap-1.5 mb-2">
          <span class="zaq-field-label-uppercase self-center">
            Filtering
          </span>
          <button
            :for={filter <- @active_filters}
            phx-click="remove_content_filter"
            phx-value-source_prefix={filter.source_prefix}
            class="zaq-chat-composer-filter-chip zaq-text-body-sm"
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

        <form id="chat-form" phx-submit="send_message" class="flex gap-3 items-stretch">
          <div
            id="content-filter-wrapper"
            class="zaq-chat-composer-field-wrap flex-1 relative min-h-0"
            phx-hook="ContentFilter"
          >
            <div
              :if={@filter_suggestions != []}
              class="absolute bottom-full mb-1 left-0 right-0 zaq-chat-composer-filter-autocomplete"
            >
              <%= for {connector, suggestions} <- Enum.group_by(@filter_suggestions, & &1.connector) do %>
                <div class="zaq-chat-composer-filter-autocomplete__connector">
                  <svg
                    class="w-3 h-3 flex-shrink-0"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    viewBox="0 0 24 24"
                    style="color: var(--zaq-text-color-body-secondary);"
                  >
                    <path
                      stroke-linecap="round"
                      stroke-linejoin="round"
                      d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
                    />
                  </svg>
                  <span class="zaq-field-label-uppercase">
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
                  class="group zaq-text-body-sm"
                >
                  <%= cond do %>
                    <% s.type == :current_folder -> %>
                      <svg
                        class="w-3.5 h-3.5 flex-shrink-0"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2"
                        viewBox="0 0 24 24"
                        style="color: var(--zaq-text-color-body-accent);"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
                        />
                      </svg>
                      <span
                        class="zaq-text-body flex-1"
                        style="color: var(--zaq-text-color-body-accent);"
                      >
                        Use "{s.label}" folder
                      </span>
                      <svg
                        class="w-3.5 h-3.5 flex-shrink-0"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2"
                        viewBox="0 0 24 24"
                        style="color: var(--zaq-text-color-body-accent);"
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
                        style="color: var(--zaq-text-color-body-secondary);"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
                        />
                      </svg>
                      <span class="zaq-text-body truncate flex-1">{s.label}</span>
                    <% true -> %>
                      <svg
                        class="w-3.5 h-3.5 flex-shrink-0"
                        fill="none"
                        stroke="currentColor"
                        stroke-width="2"
                        viewBox="0 0 24 24"
                        style="color: var(--zaq-text-color-body-secondary);"
                      >
                        <path
                          stroke-linecap="round"
                          stroke-linejoin="round"
                          d="M3 7v10a2 2 0 002 2h14a2 2 0 002-2V9a2 2 0 00-2-2h-6l-2-2H5a2 2 0 00-2 2z"
                        />
                      </svg>
                      <span class="zaq-text-body truncate flex-1">{s.label}</span>
                      <button
                        type="button"
                        data-select-folder-item="true"
                        data-source-prefix={s.source_prefix}
                        data-connector={s.connector}
                        data-label={s.label}
                        data-type={s.type}
                        tabindex="-1"
                        title={"Filter by #{s.label} folder"}
                        class="opacity-0 group-hover:opacity-100 zaq-text-body"
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
                        style="color: var(--zaq-text-color-body-tertiary);"
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
                "zaq-chat-composer-input zaq-text-body zaq-focus-visible transition-all duration-200",
                if(@status in @busy_statuses, do: "cursor-not-allowed", else: "")
              ]}
            ><%= @input_value %></textarea>
          </div>
          <button
            type="submit"
            disabled={@status in @busy_statuses or @input_value == ""}
            class="zaq-btn zaq-btn-icon zaq-btn-primary w-10 h-10 flex-shrink-0 self-end transition-all duration-200"
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
