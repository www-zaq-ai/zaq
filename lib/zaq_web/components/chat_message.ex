# lib/zaq_web/components/chat_message.ex
defmodule ZaqWeb.Components.ChatMessage do
  @moduledoc """
  Shared chat bubble components used by ChatLive and ConversationDetailLive.

  Both views render the same user/assistant message design:
  - User: right-aligned bubble on elevated surface (`.zaq-chat-user-bubble`)
  - Assistant: left-aligned column with ZAQ avatar, flat body on transcript surface,
    optional danger feedback for structured errors, source rows, confidence bar

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
  alias ZaqWeb.Components.AgentTracePanel
  alias ZaqWeb.Helpers.Markdown

  alias ZaqWeb.Live.BO.PreviewHelpers

  # ---------------------------------------------------------------------------
  # User bubble (right-aligned, elevated surface)
  # ---------------------------------------------------------------------------

  attr :content, :string, required: true
  attr :timestamp, :any, required: true
  attr :filters, :list, default: []

  slot :actions

  def user_bubble(assigns) do
    assigns = assign(assigns, :body_html, build_body_html(assigns.content, assigns.filters))

    ~H"""
    <div class="flex justify-end animate-slide-in-right" data-testid="chat-user-bubble">
      <div class="max-w-[70%]">
        <div class="zaq-chat-user-bubble">
          <%!-- Use div (not p): body_html may include buttons from @-filters; p+interactive HTML breaks layout in browsers. --%>
          <div class="zaq-text-body whitespace-pre-wrap">{@body_html}</div>
        </div>
        <div class="flex items-center justify-end gap-2 mt-1 pr-1">
          <span class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
            {format_time(@timestamp)}
          </span>
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
  # When set, the body div receives a stable id for live message updates.
  attr :msg_id, :string, default: nil
  attr :confidence, :float, default: nil
  # List of sources — strings (file paths) or maps with "path" and optional "index"
  attr :sources, :list, default: []
  attr :is_error, :boolean, default: false
  attr :error_type, :atom, default: nil
  attr :source_click_event, :string, default: nil
  attr :source_click_target, :string, default: nil

  slot :actions

  def assistant_bubble(assigns) do
    assigns =
      assigns
      |> assign(:rendered_content, assigns.content |> Markdown.render() |> Phoenix.HTML.raw())
      |> assign_error_parts()

    ~H"""
    <div class="flex justify-start min-w-0 animate-slide-in-left" data-testid="chat-assistant-bubble">
      <div class="flex min-w-0 max-w-[82%] gap-4">
        <div class="shrink-0 mt-0.5">
          <img
            src={~p"/images/zaq.png"}
            alt="ZAQ"
            class="w-8 h-8 rounded-lg object-contain"
          />
        </div>

        <div class="flex-1 min-w-0">
          <%= if @is_error && (@error_detail || @error_type != nil) do %>
            <%= if @error_type == :budget_exceeded do %>
              <p
                class="zaq-text-body-sm leading-relaxed mb-2"
                style="color: var(--zaq-text-color-body-danger);"
              >
                {@error_summary}
              </p>
              <div class="mt-1 mb-2">
                <p class="zaq-text-body-sm mb-3" style="color: var(--zaq-text-color-body-success);">
                  Top up your wallet to continue using ZAQ Router.
                </p>
                <a
                  href={@portal_url}
                  target="_blank"
                  rel="noopener noreferrer"
                  class="zaq-btn zaq-btn-primary zaq-btn-text_label-default inline-flex items-center gap-1.5"
                >
                  Top up wallet
                  <svg
                    width="12"
                    height="12"
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    stroke-width="2"
                    stroke-linecap="round"
                    stroke-linejoin="round"
                  >
                    <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
                    <polyline points="15 3 21 3 21 9" />
                    <line x1="10" y1="14" x2="21" y2="3" />
                  </svg>
                </a>
              </div>
            <% else %>
              <div
                class="zaq-feedback-banner zaq-danger zaq-text-body-sm"
                style="flex-direction: column; align-items: stretch;"
              >
                <p class="leading-relaxed mb-2" style="color: inherit;">{@error_summary}</p>
                <div class="relative">
                  <pre
                    class="zaq-text-code leading-relaxed overflow-x-auto whitespace-pre-wrap break-all"
                    style="color: inherit;"
                  >{@error_detail}</pre>
                  <button
                    type="button"
                    phx-click="copy_message"
                    phx-value-text={@error_detail}
                    class="zaq-chat-message__icon-btn absolute top-1.5 right-1.5"
                    style="color: inherit;"
                    title="Copy error detail"
                  >
                    <svg
                      width="11"
                      height="11"
                      viewBox="0 0 24 24"
                      fill="none"
                      stroke="currentColor"
                      stroke-width="2"
                      stroke-linecap="round"
                      stroke-linejoin="round"
                    >
                      <rect x="9" y="9" width="13" height="13" rx="2"></rect>
                      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
                    </svg>
                  </button>
                </div>
              </div>
            <% end %>
          <% else %>
            <%!-- Body — markdown is rendered before display and patched immediately. --%>
            <div
              id={@msg_id && "msg-body-#{@msg_id}"}
              class="zaq-text-body leading-relaxed [&>p]:mb-2 [&>p:last-child]:mb-0 [&>ul]:list-disc [&>ul]:pl-4 [&>ol]:list-decimal [&>ol]:pl-4"
              style={
                if(@is_error,
                  do: "color: var(--zaq-text-color-body-danger);",
                  else: "color: var(--zaq-text-color-body-default);"
                )
              }
            >
              {@rendered_content}
            </div>
          <% end %>

          <%!-- Source references (flat rows) --%>
          <div
            :if={@sources != []}
            class="grid grid-cols-2 gap-1.5 mt-3 pt-2.5"
            style="border-top: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default);"
          >
            <.source_card
              :for={source <- @sources}
              source={source}
              click_event={@source_click_event}
              click_target={@source_click_target}
            />
          </div>

          <%!-- Meta row: timestamp + confidence bar + actions --%>
          <div class="flex items-center gap-2 mt-1.5 ml-0.5">
            <span class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
              {format_time(@timestamp)}
            </span>

            <%!-- Confidence bar --%>
            <div
              :if={@confidence && @confidence > 0}
              class="flex items-center gap-1.5"
              title={"#{trunc(Float.round(@confidence * 100, 0))}% confidence"}
            >
              <div
                class="w-16 h-1.5 rounded-full overflow-hidden box-border"
                style="background-color: var(--zaq-surface-color-raised); border: var(--zaq-border-thickness-default) solid var(--zaq-border-color-default);"
              >
                <div class="h-full rounded-full" style={confidence_bar_fill_style(@confidence)} />
              </div>
              <span class="zaq-text-caption" style="color: var(--zaq-text-color-body-tertiary);">
                {trunc(Float.round(@confidence * 100, 0))}%
              </span>
            </div>

            <%!-- Actions slot (copy/feedback in chat, ratings in conversation detail) --%>
            <div class="flex items-center gap-0.5">
              {render_slot(@actions)}
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :available, :boolean, default: false
  attr :message_id, :string, required: true
  attr :open_event, :string, required: true

  def message_info_button(assigns) do
    ~H"""
    <button
      :if={@available}
      type="button"
      phx-click={@open_event}
      phx-value-id={@message_id}
      class="zaq-chat-message__icon-btn"
      style="color: var(--zaq-icon-color-default);"
      title="Show message information"
      data-testid={"message-info-#{@message_id}"}
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
        <circle cx="12" cy="12" r="10"></circle>
        <line x1="12" y1="8" x2="12" y2="12"></line>
        <line x1="12" y1="16" x2="12.01" y2="16"></line>
      </svg>
    </button>
    """
  end

  attr :text, :string, required: true
  attr :class, :string, default: ""

  def copy_action_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="copy_message"
      phx-value-text={@text}
      class={"zaq-chat-message__icon-btn #{String.trim(@class)}"}
      style="color: var(--zaq-icon-color-default);"
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
        <rect x="9" y="9" width="13" height="13" rx="2"></rect>
        <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"></path>
      </svg>
    </button>
    """
  end

  attr :message_id, :string, required: true
  attr :feedback, :atom, default: nil

  def feedback_positive_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="feedback"
      phx-value-id={@message_id}
      phx-value-type="positive"
      data-feedback-active={to_string(@feedback == :positive)}
      class="zaq-chat-message__icon-btn"
      style={
        if @feedback == :positive,
          do:
            "background-color: var(--zaq-surface-color-success); color: var(--zaq-text-color-body-success);",
          else: "color: var(--zaq-icon-color-default);"
      }
      title="Good response"
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
        <path d="M14 9V5a3 3 0 0 0-3-3l-4 9v11h11.28a2 2 0 0 0 2-1.7l1.38-9a2 2 0 0 0-2-2.3zM7 22H4a2 2 0 0 1-2-2v-7a2 2 0 0 1 2-2h3">
        </path>
      </svg>
    </button>
    """
  end

  attr :message_id, :string, required: true
  attr :feedback, :atom, default: nil

  def feedback_negative_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="feedback"
      phx-value-id={@message_id}
      phx-value-type="negative"
      data-feedback-active={to_string(@feedback == :negative)}
      class="zaq-chat-message__icon-btn"
      style={
        if @feedback == :negative,
          do:
            "background-color: var(--zaq-surface-color-danger); color: var(--zaq-text-color-body-danger);",
          else: "color: var(--zaq-icon-color-default);"
      }
      title="Poor response"
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
        <path d="M10 15v4a3 3 0 0 0 3 3l4-9V2H5.72a2 2 0 0 0-2 1.7l-1.38 9a2 2 0 0 0 2 2.3zm7-13h2.67A2.31 2.31 0 0 1 22 4v7a2.31 2.31 0 0 1-2.33 2H17">
        </path>
      </svg>
    </button>
    """
  end

  attr :visible, :boolean, default: false
  attr :message_id, :string, default: nil
  attr :message_info, :map, default: %{}
  attr :expanded_ids, :any, default: nil
  attr :close_event, :string, required: true
  attr :toggle_event, :string, required: true

  def message_info_popin(assigns) do
    assigns = assign_new(assigns, :expanded_ids, fn -> MapSet.new() end)

    ~H"""
    <div
      :if={@visible and is_binary(@message_id)}
      class="fixed inset-0 bg-black/40 backdrop-blur-sm flex items-center justify-center z-50"
      data-testid="message-info-popin"
    >
      <div class="bg-white rounded-2xl shadow-2xl p-5 w-[min(800px,95vw)] max-h-[85vh] border border-black/10 overflow-hidden">
        <div class="flex items-center justify-between mb-3">
          <p class="font-mono text-sm font-bold text-[#2c3a50]">
            Message information
          </p>
          <button
            type="button"
            phx-click={@close_event}
            class="font-mono text-[0.72rem] px-2 py-1 rounded-md border border-black/10 text-black/60 hover:bg-black/5"
          >
            Close
          </button>
        </div>

        <div class="overflow-y-auto pr-1" style="max-height: calc(85vh - 90px);">
          <AgentTracePanel.agent_trace_panel
            message_info={@message_info}
            expanded_ids={@expanded_ids}
            toggle_event={@toggle_event}
          />
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
      class="zaq-chat-source-row"
    >
      <svg
        class="w-3 h-3 flex-shrink-0"
        style="color: var(--zaq-text-color-body-accent);"
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
      <span class="zaq-text-code truncate">{source_label(@source)}</span>
    </button>

    <button
      :if={@click_event && is_nil(@preview_path)}
      type="button"
      data-testid="source-chip"
      class="zaq-chat-source-row"
      title="Preview unavailable"
      disabled
    >
      <svg
        class="w-3 h-3 flex-shrink-0"
        style="color: var(--zaq-text-color-body-tertiary);"
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
      <span class="zaq-text-code truncate">{source_label(@source)}</span>
    </button>

    <.link
      :if={is_nil(@click_event) && source_preview_path(@source) != "#"}
      navigate={source_preview_path(@source)}
      data-testid="source-chip"
      class="zaq-chat-source-row"
    >
      <svg
        class="w-3 h-3 flex-shrink-0"
        style="color: var(--zaq-text-color-body-accent);"
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
      <span class="zaq-text-code truncate">{source_label(@source)}</span>
    </.link>

    <button
      :if={is_nil(@click_event) && source_preview_path(@source) == "#"}
      type="button"
      data-testid="source-chip"
      class="zaq-chat-source-row"
      disabled
    >
      <svg
        class="w-3 h-3 flex-shrink-0"
        style="color: var(--zaq-text-color-body-tertiary);"
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
      <span class="zaq-text-code truncate">{source_label(@source)}</span>
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

  defp confidence_bar_fill_style(c) do
    w = trunc(Float.round(c * 100, 0))

    fill =
      cond do
        c >= 0.8 -> "background:var(--zaq-gradient-neon);"
        c >= 0.5 -> "background-color:var(--zaq-surface-color-elevated);"
        true -> "background-color:var(--zaq-surface-color-danger-strong);"
      end

    "width:#{w}%;#{fill}"
  end

  defp humanize_memory_label(label) when is_binary(label) do
    label
    |> String.replace("_", " ")
    |> String.replace("-", " ")
  end

  defp humanize_memory_label(_), do: "LLM general knowledge"

  defp assign_error_parts(%{is_error: true, content: content} = assigns) do
    # Prefer structured error_type from metadata; fall back to body parsing for
    # messages loaded from DB that predate the structured field.
    error_type =
      case assigns[:error_type] do
        nil -> detect_error_type_from_body(content)
        type -> type
      end

    case String.split(content, "\n", parts: 2) do
      [summary, detail] when detail != "" ->
        assigns
        |> assign(:error_summary, summary)
        |> assign(:error_detail, detail)
        |> assign(:error_type, error_type)
        |> assign(
          :portal_url,
          if(error_type == :budget_exceeded, do: portal_base_url(), else: nil)
        )

      _ ->
        assigns
        |> assign(:error_summary, content)
        |> assign(:error_detail, nil)
        |> assign(:error_type, error_type)
        |> assign(
          :portal_url,
          if(error_type == :budget_exceeded, do: portal_base_url(), else: nil)
        )
    end
  end

  defp assign_error_parts(assigns),
    do:
      assigns
      |> assign(:error_summary, nil)
      |> assign(:error_detail, nil)
      |> assign(:error_type, nil)
      |> assign(:portal_url, nil)

  defp detect_error_type_from_body(content) do
    case String.split(content, "\n", parts: 2) do
      [_summary, detail] when detail != "" ->
        case Jason.decode(detail) do
          {:ok, %{"type" => "budget_exceeded"}} -> :budget_exceeded
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp portal_base_url, do: Application.get_env(:zaq, :user_portal_base_url, "#")

  defp build_body_html(content, []), do: Phoenix.HTML.html_escape(content)

  defp build_body_html(content, filters) do
    mention_map = Map.new(filters, fn f -> {"@#{f.label}", f} end)

    html =
      Regex.split(~r/(@\S+)/, content, include_captures: true)
      |> Enum.map_join("", fn part ->
        case Map.fetch(mention_map, part) do
          {:ok, %{type: :file, source_prefix: sp}} ->
            safe_label = part |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
            safe_path = sp |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()

            ~s(<button type="button" phx-click="open_preview_modal" phx-value-path="#{safe_path}" class="underline cursor-pointer hover:opacity-80 transition-opacity">#{safe_label}</button>)

          {:ok, _folder_or_connector} ->
            safe_label = part |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
            ~s(<span class="underline opacity-80">#{safe_label}</span>)

          :error ->
            part |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
        end
      end)

    {:safe, html}
  end
end
