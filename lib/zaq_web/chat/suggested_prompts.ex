defmodule ZaqWeb.Chat.SuggestedPrompts do
  @moduledoc """
  BO Chat — starter question chips when the thread only has the welcome message.
  """

  use Phoenix.Component

  attr :suggested_questions, :list, required: true

  def suggested_prompts(assigns) do
    ~H"""
    <div class="zaq-chat-suggested-prompts-shell">
      <div class="max-w-3xl mx-auto">
        <p
          class="zaq-text-caption uppercase tracking-widest mb-2.5"
          style="color: var(--zaq-text-color-body-tertiary);"
        >
          Try asking
        </p>
        <div class="flex flex-wrap gap-2">
          <%= for {question, index} <- Enum.with_index(@suggested_questions) do %>
            <button
              id={"suggestion-#{index}"}
              phx-click="use_suggestion"
              phx-value-prompt={question}
              class="zaq-btn-pill zaq-btn-secondary zaq-btn-text_label-default zaq-focus-visible"
            >
              {question}
            </button>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
