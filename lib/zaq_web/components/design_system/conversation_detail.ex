defmodule ZaqWeb.Components.DesignSystem.ConversationDetail do
  @moduledoc """
  Shared stateless conversation presentation extracted from BO history detail.
  The hosting LiveView owns authorization, events, feedback attribution and shares.
  Only supplied messages and capabilities render; no BO session or handlers are reused.
  """
  use ZaqWeb, :html
  alias ZaqWeb.Components.ChatMessage
  alias ZaqWeb.Components.DesignSystem.Button, as: DSButton
  alias ZaqWeb.Live.BO.Communication.MessageHelpers
  import ZaqWeb.Chat.Modals, only: [feedback_modal: 1]
  import ZaqWeb.Components.DesignSystem.Table, only: [table_badge: 1]
  import ZaqWeb.Helpers.DateFormat, only: [format_date: 1, inject_date_separators: 2]

  attr :conversation, :any, required: true
  attr :messages, :list, required: true
  attr :shares, :list, default: []
  attr :back_url, :string, default: "/bo/history"
  attr :can_share, :boolean, default: true
  attr :can_rate, :boolean, default: true
  attr :show_share_dialog, :boolean, default: false
  attr :show_feedback_modal, :boolean, default: false
  attr :feedback_reasons, :list, default: []
  attr :feedback_comment, :string, default: ""
  attr :message_info_modal_for, :string, default: nil
  attr :message_info_modal, :map, default: %{}
  attr :expanded_trace_ids, :any, default: MapSet.new()
  attr :preview, :any, default: nil
  attr :artifact_url, :any, default: nil
  attr :source_preview_path, :any, default: nil
  attr :bleed, :boolean, default: true, doc: "Retains the BO transcript's existing page bleed."

  def conversation_detail(assigns) do
    ~H"""
    <div class="min-w-0 max-w-full">
      <div class="flex items-center justify-between mb-5">
        <div class="flex items-center gap-2 flex-wrap">
          <DSButton.button variant={:ghost} navigate={@back_url}>← Back</DSButton.button>
          <.table_badge status="processing">{@conversation.channel_type}</.table_badge>
          <.table_badge status={@conversation.status}>{@conversation.status}</.table_badge>
        </div>
        <DSButton.button :if={@can_share} variant={:secondary} phx-click="open_share_dialog">Share</DSButton.button>
      </div>
      <div class="flex flex-col lg:flex-row gap-6 items-start min-w-0">
        <div class={["flex-1 w-full min-w-0 rounded-xl overflow-hidden", @bleed && "-mx-8"]}>
          <div class="max-w-3xl mx-auto px-6 py-6 space-y-5">
            <%= for item <- inject_date_separators(@messages, :inserted_at) do %>
              <%= if Map.get(item, :type) == :date_separator do %>
                <div class="flex items-center gap-3 my-1">
                  <div class="flex-1 h-px" style="background:#e8e6e1;"></div>
                  <span
                    class="font-mono text-[0.62rem] uppercase tracking-widest"
                    style="color:#b8b5ae;"
                  >{format_date(item.date)}</span>
                  <div class="flex-1 h-px" style="background:#e8e6e1;"></div>
                </div>
              <% else %>
                <%= if item.role == "user" do %>
                  <ChatMessage.user_bubble
                    content={item.content}
                    timestamp={item.inserted_at}
                    attachments={MessageHelpers.attachments_from_message(item)}
                  />
                <% else %>
                  <% feedback = MessageHelpers.infer_feedback_from_ratings(item.ratings || []) %>
                  <% display = MessageHelpers.rating_feedback_display(item.ratings || []) %>
                  <ChatMessage.assistant_bubble
                    content={item.content}
                    timestamp={item.inserted_at}
                    confidence={item.confidence_score}
                    sources={item.sources || []}
                    source_click_event="open_preview_modal"
                    source_preview_path={@source_preview_path}
                    saved_feedback_reasons={display && display.reasons}
                    saved_feedback_user_comment={display && display.user_comment}
                  >
                    <:actions>
                      <ChatMessage.message_info_button
                        available={
                          MessageHelpers.message_info_available?(
                            MessageHelpers.message_info_from_message(item)
                          )
                        }
                        message_id={item.id}
                        open_event="open_message_info_modal"
                      />
                      <ChatMessage.copy_action_button text={item.content || ""} />
                      <ChatMessage.feedback_positive_button
                        :if={@can_rate}
                        message_id={item.id}
                        feedback={feedback}
                      />
                      <ChatMessage.feedback_negative_button
                        :if={@can_rate}
                        message_id={item.id}
                        feedback={feedback}
                      />
                    </:actions>
                  </ChatMessage.assistant_bubble>
                <% end %>
              <% end %>
            <% end %>
            <div :if={@messages == []} class="py-16 text-center">
              <p class="font-mono text-sm" style="color:#b8b5ae;">
                No messages yet.
              </p>
            </div>
          </div>
        </div>
        <div :if={@can_share && @shares != []} class="w-full lg:w-64 flex-shrink-0">
          <div class="bg-white rounded-xl border border-black/10 overflow-hidden">
            <div class="px-5 py-3 border-b border-black/10">
              <p class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider">Shares</p>
            </div>
            <ul class="divide-y divide-black/5">
              <li :for={share <- @shares} id={"share-#{share.id}"} class="px-4 py-3 space-y-1.5">
                <div class="flex items-center gap-1.5">
                  <span class="font-mono text-[0.62rem] px-1.5 py-0.5 rounded bg-black/5 text-black/40">{share.permission}</span>
                  <span :if={share.expires_at} class="zaq-text-caption">Expires {share.expires_at}</span>
                  <button
                    class="font-mono text-[0.62rem] text-red-500 hover:underline ml-auto"
                    phx-click="revoke_share"
                    phx-value-id={share.id}
                    data-confirm="Revoke this share?"
                  >Revoke</button>
                </div>
                <div class="flex items-center gap-1">
                  <input
                    type="text"
                    readonly
                    aria-label="Share link"
                    value={url(~p"/s/#{share.share_token}")}
                    class="font-mono text-[0.6rem] text-black/50 bg-black/[0.03] border border-black/10 rounded px-1.5 py-1 w-full min-w-0 select-all focus:outline-none"
                  />
                  <button
                    id={"copy-#{share.id}"}
                    data-share-url={url(~p"/s/#{share.share_token}")}
                    phx-hook="CopyToClipboard"
                    class="flex-shrink-0 font-mono text-[0.62rem] px-2 py-1 rounded border border-black/10 text-black/50 hover:bg-black/5 transition-colors"
                  >Copy</button>
                </div>
              </li>
            </ul>
          </div>
        </div>
      </div>
      <ZaqWeb.Components.FilePreviewModal.modal
        :if={@preview}
        preview={@preview}
        cancel_event="close_preview_modal"
      />
      <ChatMessage.message_info_popin
        visible={is_binary(@message_info_modal_for)}
        message_id={@message_info_modal_for}
        message_info={@message_info_modal}
        expanded_ids={@expanded_trace_ids}
        close_event="close_message_info_modal"
        toggle_event="toggle_trace_details"
        artifact_url={@artifact_url}
      />
      <.feedback_modal
        show_feedback_modal={@can_rate && @show_feedback_modal}
        feedback_reasons={@feedback_reasons}
        feedback_comment={@feedback_comment}
      />
      <div
        :if={@can_share && @show_share_dialog}
        id="conversation-share-dialog"
        class="fixed inset-0 bg-black/40 backdrop-blur-sm flex items-center justify-center z-50"
      >
        <div class="bg-white rounded-2xl shadow-2xl p-6 w-80 border border-black/10">
          <p class="font-mono text-sm font-bold text-[#2c3a50] mb-4">Share Conversation</p>
          <.form
            for={to_form(%{"permission" => "read"})}
            id="conversation-share-form"
            phx-submit="share"
          >
            <label
              for="share-permission"
              class="font-mono text-[0.7rem] text-black/40 uppercase tracking-wider block mb-1.5"
            >Permission</label>
            <select
              id="share-permission"
              name="permission"
              class="font-mono text-[0.78rem] text-black w-full border border-black/10 rounded-lg px-2.5 py-1.5 bg-white focus:outline-none focus:ring-1 focus:ring-[#03b6d4] mb-5"
            ><option value="read">
              Read
            </option></select>
            <div class="flex gap-2 justify-end">
              <button
                type="button"
                class="font-mono text-[0.78rem] px-3 py-1.5 rounded-lg border border-black/10 text-black/60 hover:bg-black/5 transition-colors"
                phx-click="close_share_dialog"
              >Cancel</button>
              <button
                type="submit"
                class="font-mono text-[0.78rem] font-bold px-3 py-1.5 rounded-lg bg-[#03b6d4] text-white hover:bg-[#03b6d4]/90 transition-colors"
              >Create Link</button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end
end
