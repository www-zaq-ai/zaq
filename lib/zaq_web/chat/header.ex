defmodule ZaqWeb.Chat.Header do
  @moduledoc """
  BO Chat — top bar: agent compact select and delete-conversation control.

  Styling uses `assets/css/form.css`, `.zaq-chat-header-bar` in `styles.css`, and
  `.zaq-btn` + `.zaq-btn-ghost` for the delete control from `btn.css`.
  """
  use Phoenix.Component

  import ZaqWeb.Components.SearchableSelect, only: [searchable_select: 1]

  attr :selected_agent_id, :any, required: true
  attr :available_agents, :list, required: true

  def chat_header(assigns) do
    assigns =
      assign(
        assigns,
        :agent_select_options,
        [{"Default (routing)", ""} | Enum.map(assigns.available_agents, &{&1.name, &1.id})]
      )

    ~H"""
    <div class="zaq-chat-header-bar">
      <form id="chat-agent-select-form" class="zaq-field-row-inline" phx-change="select_agent">
        <label for="chat-agent-select-trigger" class="zaq-field-label-uppercase">
          Agent
        </label>
        <div class="zaq-field-row-inline-control min-w-52">
          <.searchable_select
            id="chat-agent-select"
            name="agent_id"
            value={@selected_agent_id || ""}
            empty_label="Default (routing)"
            searchable={false}
            compact={true}
            options={@agent_select_options}
          />
        </div>
      </form>

      <button
        id="delete-chat-button"
        type="button"
        phx-click="delete_chat_confirm"
        class="zaq-btn zaq-btn-ghost"
      >
        <svg
          class="zaq-icon-sm"
          fill="none"
          stroke="currentColor"
          stroke-width="2"
          viewBox="0 0 24 24"
        >
          <path
            stroke-linecap="round"
            stroke-linejoin="round"
            d="M19 7l-.867 12.142A2 2 0 0116.138 21H7.862a2 2 0 01-1.995-1.858L5 7m5 4v6m4-6v6m1-10V4a1 1 0 00-1-1h-4a1 1 0 00-1 1v3M4 7h16"
          />
        </svg>
        <span class="zaq-btn-text_label-default">Delete chat</span>
      </button>
    </div>
    """
  end
end
