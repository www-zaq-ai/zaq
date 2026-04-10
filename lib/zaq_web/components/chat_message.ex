# lib/zaq_web/components/chat_message.ex
defmodule ZaqWeb.Components.ChatMessage do
  @moduledoc """
  Shared chat bubble components used by ChatLive and ConversationDetailLive.

  Both views render the same user/assistant bubble design:
  - User: right-aligned dark (#2c3a50) bubble
  - Assistant: left-aligned white card with ZAQ avatar, source chips, confidence bar

  Usage:

      <ChatMessage.user_bubble content={msg.body} timestamp={msg.timestamp}>
        <:actions>..copy button..</:actions>
      </ChatMessage.user_bubble>

      <ChatMessage.assistant_bubble
        content={msg.body}
        timestamp={msg.timestamp}
        confidence={msg.confidence}
        sources={msg.sources}
      >
        <:actions>..rating or feedback buttons..</:actions>
      </ChatMessage.assistant_bubble>
  """
  use Phoenix.Component
  use ZaqWeb, :verified_routes

  import ZaqWeb.Helpers.DateFormat, only: [format_time: 1]
  alias ZaqWeb.Helpers.Markdown

  alias ZaqWeb.Live.BO.PreviewHelpers

  # ---------------------------------------------------------------------------
  # User bubble (right-aligned, dark)
  # ---------------------------------------------------------------------------

  attr :content, :string, required: true
  attr :timestamp, :any, required: true

  slot :actions

  def user_bubble(assigns) do
    ~H"""
    <div class="flex justify-end animate-slide-in-right group">
      <div class="max-w-[70%]">
        <div class="text-white px-4 py-3 rounded-2xl rounded-br-none shadow-sm zaq-bg-user-bubble">
          <p class="text-[0.85rem] leading-relaxed whitespace-pre-wrap">{@content}</p>
        </div>
        <div class="flex items-center justify-end gap-2 mt-1 pr-1 msg-actions">
          <span class="text-[0.62rem] zaq-text-muted">{format_time(@timestamp)}</span>
          {render_slot(@actions)}
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Assistant bubble (left-aligned, white with ZAQ avatar)
  # ---------------------------------------------------------------------------

  attr :content, :string, required: true
  attr :timestamp, :any, required: true
  # When set, the body div receives id + phx-hook="Typewriter" + phx-update="ignore"
  attr :msg_id, :string, default: nil
  attr :confidence, :float, default: nil
  # List of sources — strings (file paths) or maps with "path" and optional "index"
  attr :sources, :list, default: []
  attr :is_error, :boolean, default: false
  attr :source_click_event, :string, default: nil
  attr :source_click_target, :string, default: nil

  slot :actions

  def assistant_bubble(assigns) do
    assigns = assign(assigns, :rendered_content, Markdown.render(assigns.content))

    ~H"""
    <div class="flex justify-start animate-slide-in-left group">
      <div class="flex gap-3 max-w-[82%]">
        <%!-- ZAQ avatar --%>
        <div class="flex-shrink-0 mt-0.5">
          <img src={~p"/images/zaq.png"} alt="ZAQ" class="w-7 h-7 rounded-lg object-contain" />
        </div>

        <div class="flex-1 min-w-0">
          <%!-- Bubble card --%>
          <div class={[
            "px-4 py-3 rounded-2xl rounded-bl-none border shadow-sm",
            if(@is_error, do: "bg-red-50 border-red-200", else: "bg-white zaq-card-border-soft")
          ]}>
            <%!-- Body — with optional Typewriter hook for live rendering --%>
            <div
              id={@msg_id && "msg-body-#{@msg_id}"}
              phx-hook={@msg_id && "Typewriter"}
              phx-update={@msg_id && "ignore"}
              class={[
                "text-[0.85rem] leading-relaxed [&>p]:mb-2 [&>p:last-child]:mb-0 [&>ul]:list-disc [&>ul]:pl-4 [&>ol]:list-decimal [&>ol]:pl-4",
                if(@is_error, do: "text-red-600", else: "text-[#2c2b28]")
              ]}
            >
              {Phoenix.HTML.raw(@rendered_content)}
            </div>

            <%!-- Source cards --%>
            <div
              :if={@sources != []}
              class="grid grid-cols-2 gap-1.5 mt-3 pt-2.5 zaq-divider-top-soft"
            >
              <.source_card
                :for={source <- @sources}
                source={source}
                click_event={@source_click_event}
                click_target={@source_click_target}
              />
            </div>
          </div>

          <%!-- Meta row: timestamp + confidence bar + actions --%>
          <div class="flex items-center gap-2 mt-1.5 ml-0.5">
            <span class="text-[0.62rem] zaq-text-muted">{format_time(@timestamp)}</span>

            <%!-- Confidence bar --%>
            <div
              :if={@confidence && @confidence > 0}
              class="flex items-center gap-1.5"
              title={"#{trunc(Float.round(@confidence * 100, 0))}% confidence"}
            >
              <div class="w-16 h-1.5 rounded-full overflow-hidden zaq-confidence-track">
                <div
                  class="h-full rounded-full"
                  style={"width:#{trunc(Float.round(@confidence * 100, 0))}%; background:#{confidence_color(@confidence)};"}
                />
              </div>
              <span class="text-[0.62rem] zaq-text-muted">
                {trunc(Float.round(@confidence * 100, 0))}%
              </span>
            </div>

            <%!-- Actions slot (copy/feedback in chat, ratings in conversation detail) --%>
            <div class="flex items-center gap-0.5 msg-actions">
              {render_slot(@actions)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # ---------------------------------------------------------------------------
  # Source card component
  # ---------------------------------------------------------------------------

  attr :source, :any, required: true
  attr :click_event, :string, default: nil
  attr :click_target, :string, default: nil

  defp source_card(assigns) do
    assigns =
      assigns
      |> assign(:preview_path, source_preview_path_for_modal(assigns.source))
      |> assign(:click_target_attrs, click_target_attrs(assigns.click_target))

    ~H"""
    <button
      :if={@click_event && @preview_path}
      type="button"
      phx-click={@click_event}
      phx-value-path={@preview_path}
      {@click_target_attrs}
      data-testid="source-chip"
      class="flex items-center gap-2 px-2.5 py-2 rounded-lg border transition-colors min-w-0 zaq-source-card"
    >
      <svg
        class="w-3 h-3 flex-shrink-0 zaq-source-card-icon"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
        />
      </svg>
      <span class="font-mono text-[0.68rem] truncate">{source_label(@source)}</span>
    </button>

    <button
      :if={@click_event && is_nil(@preview_path)}
      type="button"
      data-testid="source-chip"
      class="flex items-center gap-2 px-2.5 py-2 rounded-lg border min-w-0 opacity-60 cursor-not-allowed zaq-source-card"
      title="Preview unavailable"
      disabled
    >
      <svg
        class="w-3 h-3 flex-shrink-0 zaq-source-card-icon-muted"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
        />
      </svg>
      <span class="font-mono text-[0.68rem] truncate">{source_label(@source)}</span>
    </button>

    <.link
      :if={is_nil(@click_event) && source_preview_path(@source) != "#"}
      navigate={source_preview_path(@source)}
      data-testid="source-chip"
      class="flex items-center gap-2 px-2.5 py-2 rounded-lg border transition-colors min-w-0 zaq-source-card"
    >
      <svg
        class="w-3 h-3 flex-shrink-0 zaq-source-card-icon"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
        />
      </svg>
      <span class="font-mono text-[0.68rem] truncate">{source_label(@source)}</span>
    </.link>

    <button
      :if={is_nil(@click_event) && source_preview_path(@source) == "#"}
      type="button"
      data-testid="source-chip"
      class="flex items-center gap-2 px-2.5 py-2 rounded-lg border min-w-0 opacity-60 cursor-not-allowed zaq-source-card"
      disabled
    >
      <svg
        class="w-3 h-3 flex-shrink-0 zaq-source-card-icon-muted"
        fill="none"
        stroke="currentColor"
        stroke-width="2"
        viewBox="0 0 24 24"
      >
        <path
          stroke-linecap="round"
          stroke-linejoin="round"
          d="M9 12h6m-6 4h6m2 5H7a2 2 0 01-2-2V5a2 2 0 012-2h5.586a1 1 0 01.707.293l5.414 5.414a1 1 0 01.293.707V19a2 2 0 01-2 2z"
        />
      </svg>
      <span class="font-mono text-[0.68rem] truncate">{source_label(@source)}</span>
    </button>
    """
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp source_label(%{"index" => index, "path" => path}) when is_integer(index),
    do: "[#{index}] #{Path.basename(path)}"

  defp source_label(%{"index" => index, "type" => "memory", "label" => label})
       when is_integer(index),
       do: "[#{index}] Internal memory - #{humanize_memory_label(label)}"

  defp source_label(%{index: index, path: path}) when is_integer(index),
    do: "[#{index}] #{Path.basename(path)}"

  defp source_label(%{index: index, type: "memory", label: label}) when is_integer(index),
    do: "[#{index}] Internal memory - #{humanize_memory_label(label)}"

  defp source_label(source) when is_binary(source), do: Path.basename(source)
  defp source_label(%{"path" => path}), do: Path.basename(path)
  defp source_label(%{"title" => title}), do: title
  defp source_label(_), do: "source"

  defp source_preview_path_for_modal(source) when is_binary(source) and source != "" do
    if PreviewHelpers.previewable_path?(source), do: source, else: nil
  end

  defp source_preview_path_for_modal(%{"path" => path}) when is_binary(path) do
    if PreviewHelpers.previewable_path?(path), do: path, else: nil
  end

  defp source_preview_path_for_modal(%{"type" => "memory"}), do: nil

  defp source_preview_path_for_modal(%{path: path}) when is_binary(path) do
    if PreviewHelpers.previewable_path?(path), do: path, else: nil
  end

  defp source_preview_path_for_modal(_), do: nil

  defp source_preview_path(source) when is_binary(source) and source != "",
    do: "/bo/preview/#{source}"

  defp source_preview_path(%{"path" => path}) when is_binary(path) and path != "",
    do: "/bo/preview/#{path}"

  defp source_preview_path(%{"type" => "memory"}), do: "#"

  defp source_preview_path(%{path: path}) when is_binary(path) and path != "",
    do: "/bo/preview/#{path}"

  defp source_preview_path(%{"id" => id}) when is_binary(id) and id != "",
    do: "/bo/files/#{id}"

  defp source_preview_path(_), do: "#"

  defp click_target_attrs(nil), do: %{}
  defp click_target_attrs(target), do: %{"phx-target" => target}

  defp confidence_color(c) when c >= 0.8, do: "#22c55e"
  defp confidence_color(c) when c >= 0.5, do: "#f59e0b"
  defp confidence_color(_), do: "#ef4444"

  defp humanize_memory_label(label) when is_binary(label) do
    label
    |> String.replace("_", " ")
    |> String.replace("-", " ")
  end

  defp humanize_memory_label(_), do: "LLM general knowledge"
end
