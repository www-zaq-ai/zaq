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
  attr :filters, :list, default: []

  slot :actions

  def user_bubble(assigns) do
    assigns = assign(assigns, :body_html, build_body_html(assigns.content, assigns.filters))

    ~H"""
    <div class="flex justify-end animate-slide-in-right group">
      <div class="max-w-[70%]">
        <div class="text-white px-4 py-3 rounded-2xl rounded-br-none shadow-sm zaq-bg-user-bubble">
          <p class="text-[0.85rem] leading-relaxed whitespace-pre-wrap">{@body_html}</p>
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
                if(@is_error, do: "text-red-600", else: "zaq-text-ink")
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

  attr :tool_calls, :list, default: []
  attr :message_id, :string, required: true
  attr :open_event, :string, required: true

  def tool_calls_info_button(assigns) do
    ~H"""
    <button
      :if={Enum.any?(@tool_calls)}
      type="button"
      phx-click={@open_event}
      phx-value-id={@message_id}
      class="p-1.5 rounded-lg transition-all hover:bg-[#eeece8]"
      style="color:#b8b5ae;"
      title="Show tool calls"
      data-testid={"tool-calls-info-#{@message_id}"}
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
      class={"p-1.5 rounded-lg transition-all hover:bg-[#eeece8] #{String.trim(@class)}"}
      style="color:#b8b5ae;"
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
      class={[
        "p-1.5 rounded-lg transition-all",
        if(@feedback == :positive, do: "bg-emerald-50 text-emerald-500", else: "hover:bg-[#eeece8]")
      ]}
      style={if @feedback != :positive, do: "color:#b8b5ae;", else: ""}
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
      class={[
        "p-1.5 rounded-lg transition-all",
        if(@feedback == :negative, do: "bg-red-50 text-red-400", else: "hover:bg-[#eeece8]")
      ]}
      style={if @feedback != :negative, do: "color:#b8b5ae;", else: ""}
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
  attr :tool_calls, :list, default: []
  attr :expanded_ids, :any, default: nil
  attr :close_event, :string, required: true
  attr :toggle_event, :string, required: true

  def tool_calls_popin(assigns) do
    assigns =
      assigns
      |> assign_new(:expanded_ids, fn -> MapSet.new() end)

    ~H"""
    <div
      :if={@visible and is_binary(@message_id)}
      class="fixed inset-0 bg-black/40 backdrop-blur-sm flex items-center justify-center z-50"
      data-testid="tool-calls-popin"
    >
      <div class="bg-white rounded-2xl shadow-2xl p-5 w-[min(800px,95vw)] max-h-[85vh] border border-black/10 overflow-hidden">
        <div class="flex items-center justify-between mb-3">
          <p class="font-mono text-sm font-bold text-[#2c3a50]">Tool calls</p>
          <button
            type="button"
            phx-click={@close_event}
            class="font-mono text-[0.72rem] px-2 py-1 rounded-md border border-black/10 text-black/60 hover:bg-black/5"
          >
            Close
          </button>
        </div>

        <div class="overflow-y-auto pr-1" style="max-height: calc(85vh - 90px);">
          <ul class="space-y-2">
            <li
              :for={tc <- sort_tool_calls_chronologically(@tool_calls)}
              class="border border-[#e8e6e1] rounded-xl overflow-hidden"
            >
              <button
                type="button"
                phx-click={@toggle_event}
                phx-value-tool_id={tool_call_id(tc)}
                class="w-full text-left px-3 py-2.5 flex items-center justify-between hover:bg-[#faf9f7]"
                data-testid={"tool-call-row-#{tool_call_id(tc)}"}
              >
                <span class="font-mono text-[0.75rem] text-[#2c2b28] truncate">
                  {friendly_tool_name(Map.get(tc, :tool_name) || Map.get(tc, "tool_name"))}
                </span>
                <span class="font-mono text-[0.62rem] text-[#9e9b94]">
                  {format_response_time(
                    Map.get(tc, :response_time_ms) || Map.get(tc, "response_time_ms")
                  )}
                </span>
              </button>

              <div
                :if={MapSet.member?(@expanded_ids, tool_call_id(tc))}
                class="px-3 pb-3 pt-1 bg-[#fcfcfb] border-t border-[#f0ede8]"
                data-testid={"tool-call-details-#{tool_call_id(tc)}"}
              >
                <p class="font-mono text-[0.68rem] text-[#7f7c76]">
                  <span class="font-bold">Timestamp:</span>
                  {format_detail_value(Map.get(tc, :timestamp) || Map.get(tc, "timestamp"))}
                </p>
                <p class="font-mono text-[0.68rem] text-[#7f7c76] mt-2 mb-1">
                  <span class="font-bold">Params</span>
                </p>
                <pre class="font-mono text-[0.66rem] leading-relaxed text-[#2c2b28] bg-white border border-[#ece9e3] rounded-lg p-2 overflow-x-auto">{pretty_json(Map.get(tc, :params) || Map.get(tc, "params"))}</pre>
                <p class="font-mono text-[0.68rem] text-[#7f7c76] mt-2 mb-1">
                  <span class="font-bold">Response</span>
                </p>
                <pre class="font-mono text-[0.66rem] leading-relaxed text-[#2c2b28] bg-white border border-[#ece9e3] rounded-lg p-2 overflow-x-auto">{pretty_json(Map.get(tc, :response) || Map.get(tc, "response"))}</pre>
                <p class="font-mono text-[0.68rem] text-[#7f7c76] mt-2">
                  <span class="font-bold">Response time:</span>
                  {format_response_time(
                    Map.get(tc, :response_time_ms) || Map.get(tc, "response_time_ms")
                  )}
                </p>
              </div>
            </li>
          </ul>
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

  defp friendly_tool_name(tool_name) when is_binary(tool_name) and tool_name != "" do
    tool_name
    |> String.replace(~r/[_\.]+/, " ")
    |> String.trim()
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp friendly_tool_name(_), do: "Unknown tool"

  defp tool_call_id(tc) do
    id =
      Map.get(tc, :tool_call_id) ||
        Map.get(tc, "tool_call_id") ||
        Map.get(tc, :timestamp) ||
        Map.get(tc, "timestamp") ||
        inspect(tc)

    if is_binary(id), do: id, else: inspect(id)
  end

  defp format_response_time(ms) when is_integer(ms), do: "#{ms} ms"
  defp format_response_time(ms) when is_float(ms), do: "#{Float.round(ms, 2)} ms"
  defp format_response_time(_), do: "n/a"

  defp format_detail_value(nil), do: "n/a"
  defp format_detail_value(""), do: "n/a"
  defp format_detail_value(value) when is_binary(value), do: value
  defp format_detail_value(value), do: inspect(value)

  defp pretty_json(nil), do: "null"

  defp pretty_json(value) do
    case Jason.encode(value, pretty: true) do
      {:ok, json} -> json
      _ -> inspect(value, pretty: true, limit: :infinity)
    end
  end

  defp sort_tool_calls_chronologically(tool_calls) when is_list(tool_calls) do
    Enum.sort_by(tool_calls, &tool_call_timestamp_sort_key/1, :asc)
  end

  defp sort_tool_calls_chronologically(_), do: []

  defp tool_call_timestamp_sort_key(tc) when is_map(tc) do
    timestamp = Map.get(tc, :timestamp) || Map.get(tc, "timestamp")

    case DateTime.from_iso8601(to_string(timestamp || "")) do
      {:ok, dt, _offset} -> {0, DateTime.to_unix(dt, :microsecond)}
      _ -> {1, 0}
    end
  end

  defp tool_call_timestamp_sort_key(_), do: {1, 0}

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

    Phoenix.HTML.raw(html)
  end
end
