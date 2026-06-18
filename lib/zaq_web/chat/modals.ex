defmodule ZaqWeb.Chat.Modals do
  @moduledoc """
  BO Chat — delete confirmation and negative-feedback dialogs.
  """

  use Phoenix.Component

  attr :show_delete_confirm, :boolean, required: true

  def delete_confirm_modal(assigns) do
    ~H"""
    <%= if @show_delete_confirm do %>
      <div
        id="delete-confirm-modal"
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm"
        phx-click="close_delete_modal"
      >
        <div
          class="bg-white rounded-2xl shadow-2xl w-full max-w-sm mx-4 overflow-hidden"
          phx-click="noop"
        >
          <div class="px-6 pt-6 pb-4">
            <h3 class="text-base font-semibold mb-2" style="color:#2c2b28;">Delete this chat?</h3>
            <p class="text-sm" style="color:#9e9b94;">
              This conversation will be permanently deleted and cannot be recovered.
            </p>
          </div>
          <div class="flex items-center justify-end gap-3 px-6 pb-5">
            <button
              id="delete-modal-cancel"
              phx-click="close_delete_modal"
              class="px-4 py-2 text-sm transition-colors"
              style="color:#9e9b94;"
            >
              Cancel
            </button>
            <button
              id="delete-modal-confirm"
              phx-click="delete_chat"
              class="px-5 py-2 text-sm font-medium text-white rounded-lg transition-all active:scale-95"
              style="background:#ef4444;"
            >
              Delete
            </button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end

  attr :show_feedback_modal, :boolean, required: true
  attr :feedback_reasons, :list, required: true
  attr :feedback_comment, :string, required: true

  def feedback_modal(assigns) do
    ~H"""
    <%= if @show_feedback_modal do %>
      <div
        id="feedback-modal"
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/40 backdrop-blur-sm"
        phx-click="close_feedback_modal"
      >
        <div
          class="bg-white rounded-2xl shadow-2xl w-full max-w-md mx-4 overflow-hidden"
          phx-click="noop"
        >
          <div class="flex items-center justify-between px-6 pt-5 pb-3">
            <h3 class="text-base font-semibold" style="color:#2c2b28;">Provide feedback</h3>
            <button
              phx-click="close_feedback_modal"
              class="transition-colors text-[#b8b5ae] hover:text-[#5c5a55]"
            >
              <svg
                class="w-5 h-5"
                fill="none"
                stroke="currentColor"
                stroke-width="2"
                viewBox="0 0 24 24"
              >
                <path stroke-linecap="round" stroke-linejoin="round" d="M6 18L18 6M6 6l12 12" />
              </svg>
            </button>
          </div>
          <div class="px-6 pb-4">
            <div class="flex flex-wrap gap-2 mb-4">
              <%= for reason <- Zaq.Engine.Telemetry.FeedbackReasons.list() do %>
                <button
                  phx-click="toggle_feedback_reason"
                  phx-value-reason={reason}
                  data-reason-selected={to_string(reason in @feedback_reasons)}
                  class="px-3.5 py-1.5 rounded-full text-sm border transition-all duration-150"
                  style={
                    if reason in @feedback_reasons,
                      do: "background:#03b6d4; color:white; border-color:#03b6d4;",
                      else: "background:#faf9f7; color:#5c5a55; border-color:#e0ddd8;"
                  }
                >
                  {reason}
                </button>
              <% end %>
            </div>
            <textarea
              phx-change="update_feedback_comment"
              name="comment"
              rows="4"
              placeholder="Tell us more (optional)"
              class="w-full text-sm rounded-xl px-4 py-3 resize-none focus:outline-none focus:ring-2 focus:ring-[#03b6d4]/20 transition-all"
              style="border:1px solid #e0ddd8; background:#faf9f7; color:#2c2b28;"
            ><%= @feedback_comment %></textarea>
          </div>
          <div class="flex items-center justify-end gap-3 px-6 pb-5">
            <button
              phx-click="close_feedback_modal"
              class="px-4 py-2 text-sm transition-colors"
              style="color:#9e9b94;"
            >
              Cancel
            </button>
            <button
              id="submit-feedback-button"
              phx-click="submit_feedback"
              class="px-5 py-2 text-sm font-medium text-white rounded-lg transition-all active:scale-95"
              style="background:#03b6d4;"
            >
              Submit
            </button>
          </div>
        </div>
      </div>
    <% end %>
    """
  end
end
