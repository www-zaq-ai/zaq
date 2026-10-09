defmodule ZaqWeb.Components.DesignSystem.ChannelMessageTimeline do
  @moduledoc """
  Bounded communication-message timeline. The caller supplies only the Engine's
  authorized public projection, never private trace or execution fields.
  """

  use Phoenix.Component

  attr :messages, :list, required: true

  def channel_message_timeline(assigns) do
    ~H"""
    <ol class="zaq-layout-stack" aria-label="Transcript messages">
      <li :for={message <- @messages} class="zaq-card-default zaq-layout-stack-tight">
        <div class="zaq-layout-inline-compact flex-wrap">
          <strong class="zaq-text-body">{message.author_name || message.author_id || "Unknown author"}</strong>
          <span class="zaq-pill zaq-pill--elevated zaq-text-caption">{message.role}</span>
          <span class="zaq-text-caption">Position {message.position}</span>
        </div>
        <p class="zaq-text-body">{message.content}</p>
        <p :for={attachment <- message.attachments} class="zaq-field-helper">
          Attachment: {attachment["name"] || attachment["id"] || "File"} (descriptor only)
        </p>
      </li>
    </ol>
    """
  end
end
