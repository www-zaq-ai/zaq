defmodule ZaqWeb.Chat.SuggestedPrompts do
  @moduledoc """
  BO Chat — starter question chips when the thread only has the welcome message.
  """

  use Phoenix.Component

  attr :suggested_questions, :list, required: true

  def suggested_prompts(assigns) do
    ~H"""
    <div class="flex-shrink-0 px-6 py-3 border-t border-[#e8e6e1] bg-white">
      <div class="max-w-3xl mx-auto">
        <p
          class="text-[0.65rem] font-mono uppercase tracking-widest mb-2.5"
          style="color:#b8b5ae;"
        >
          Try asking
        </p>
        <div class="flex flex-wrap gap-2">
          <%= for {question, index} <- Enum.with_index(@suggested_questions) do %>
            <button
              id={"suggestion-#{index}"}
              phx-click="use_suggestion"
              phx-value-prompt={question}
              class="text-[0.78rem] rounded-full px-3.5 py-1.5 border transition-all text-[#5c5a55] border-[#e0ddd8] bg-[#faf9f7] hover:text-[#03b6d4] hover:border-[#03b6d4] hover:bg-[#f0f9fb]"
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
