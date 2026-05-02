defmodule ZaqWeb.Live.BO.Communication.ConversationDetailLive do
  @moduledoc """
  BO LiveView for viewing a conversation thread with per-message ratings and share management.
  """

  use ZaqWeb, :live_view

  alias Zaq.NodeRouter
  alias ZaqWeb.Live.BO.PreviewHelpers

  import ZaqWeb.Helpers.DateFormat, only: [format_date: 1, inject_date_separators: 2]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    conversation =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :get_conversation!, [id])

    messages =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_messages, [conversation])

    messages = if is_list(messages), do: messages, else: []

    shares =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_shares, [conversation])

    shares = if is_list(shares), do: shares, else: []

    {:ok,
     socket
     |> assign(:page_title, conversation.title || "Conversation")
     |> assign(:current_path, "/bo/conversations/#{id}")
     |> assign(:conversation, conversation)
     |> assign(:messages, messages)
     |> assign(:shares, shares)
     |> assign(:show_share_dialog, false)
     |> assign(:show_feedback_modal, false)
     |> assign(:feedback_message_id, nil)
     |> assign(:feedback_reasons, [])
     |> assign(:feedback_comment, "")
     |> assign(:tool_calls_modal_for, nil)
     |> assign(:tool_calls_modal_entries, [])
     |> assign(:expanded_tool_call_ids, MapSet.new())
     |> assign(:preview, nil)}
  rescue
    Ecto.NoResultsError ->
      {:ok,
       socket
       |> put_flash(:error, "Conversation not found.")
       |> redirect(to: ~p"/bo/chat")}
  end

  @impl true
  def handle_event("copy_message", %{"text" => text}, socket) do
    {:noreply, push_event(socket, "clipboard", %{text: text})}
  end

  def handle_event("feedback", %{"id" => id, "type" => "positive"}, socket) do
    current_user = socket.assigns[:current_user]
    msg = find_message(socket.assigns.messages, id)

    if msg do
      rater_attrs =
        if current_user,
          do: %{user_id: current_user.id, rating: 5},
          else: %{channel_user_id: "bo_anonymous", rating: 5}

      NodeRouter.call(:engine, Zaq.Engine.Conversations, :rate_message_by_id, [
        msg.id,
        rater_attrs
      ])
    end

    {:noreply, assign(socket, :messages, refresh_messages(socket.assigns.conversation))}
  end

  def handle_event("feedback", %{"id" => id, "type" => "negative"}, socket) do
    {:noreply,
     socket
     |> assign(:show_feedback_modal, true)
     |> assign(:feedback_message_id, id)
     |> assign(:feedback_reasons, [])
     |> assign(:feedback_comment, "")}
  end

  def handle_event("close_feedback_modal", _params, socket) do
    {:noreply, assign(socket, :show_feedback_modal, false)}
  end

  def handle_event("toggle_feedback_reason", %{"reason" => reason}, socket) do
    reasons = socket.assigns.feedback_reasons

    updated =
      if reason in reasons,
        do: List.delete(reasons, reason),
        else: reasons ++ [reason]

    {:noreply, assign(socket, :feedback_reasons, updated)}
  end

  def handle_event("update_feedback_comment", %{"comment" => comment}, socket) do
    {:noreply, assign(socket, :feedback_comment, comment)}
  end

  def handle_event("submit_feedback", _params, socket) do
    id = socket.assigns.feedback_message_id
    reasons = socket.assigns.feedback_reasons
    comment = socket.assigns.feedback_comment
    current_user = socket.assigns[:current_user]

    msg = find_message(socket.assigns.messages, id)

    if msg do
      full_comment =
        [Enum.join(reasons, ", "), comment]
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n")

      rater_attrs =
        if current_user,
          do: %{
            user_id: current_user.id,
            rating: 1,
            comment: full_comment,
            feedback_reasons: reasons
          },
          else: %{
            channel_user_id: "bo_anonymous",
            rating: 1,
            comment: full_comment,
            feedback_reasons: reasons
          }

      NodeRouter.call(:engine, Zaq.Engine.Conversations, :rate_message_by_id, [
        msg.id,
        rater_attrs
      ])
    end

    {:noreply,
     socket
     |> assign(:show_feedback_modal, false)
     |> assign(:messages, refresh_messages(socket.assigns.conversation))}
  end

  def handle_event("open_share_dialog", _params, socket) do
    {:noreply, assign(socket, :show_share_dialog, true)}
  end

  def handle_event("close_share_dialog", _params, socket) do
    {:noreply, assign(socket, :show_share_dialog, false)}
  end

  def handle_event("open_preview_modal", %{"path" => path}, socket) do
    {:noreply, PreviewHelpers.open_preview(socket, path)}
  end

  def handle_event("close_preview_modal", _params, socket) do
    {:noreply, PreviewHelpers.close_preview(socket)}
  end

  def handle_event("open_tool_calls_modal", %{"id" => id}, socket) do
    tool_calls =
      socket.assigns.messages
      |> find_message(id)
      |> tool_calls_for_message()

    {:noreply,
     socket
     |> assign(:tool_calls_modal_for, id)
     |> assign(:tool_calls_modal_entries, tool_calls)
     |> assign(:expanded_tool_call_ids, MapSet.new())}
  end

  def handle_event("close_tool_calls_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:tool_calls_modal_for, nil)
     |> assign(:tool_calls_modal_entries, [])
     |> assign(:expanded_tool_call_ids, MapSet.new())}
  end

  def handle_event("toggle_tool_call_details", %{"tool_id" => tool_id}, socket) do
    expanded = socket.assigns.expanded_tool_call_ids

    updated =
      if MapSet.member?(expanded, tool_id) do
        MapSet.delete(expanded, tool_id)
      else
        MapSet.put(expanded, tool_id)
      end

    {:noreply, assign(socket, :expanded_tool_call_ids, updated)}
  end

  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("share", %{"permission" => permission}, socket) do
    conv = socket.assigns.conversation

    NodeRouter.call(:engine, Zaq.Engine.Conversations, :share_conversation, [
      conv,
      %{permission: permission}
    ])

    shares =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_shares, [conv])

    shares = if is_list(shares), do: shares, else: []

    {:noreply,
     socket
     |> assign(:shares, shares)
     |> assign(:show_share_dialog, false)}
  end

  def handle_event("revoke_share", %{"id" => share_id}, socket) do
    share = Enum.find(socket.assigns.shares, &(&1.id == share_id))

    if share do
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :revoke_share, [share])

      conv = socket.assigns.conversation

      shares =
        NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_shares, [conv])

      shares = if is_list(shares), do: shares, else: []
      {:noreply, assign(socket, :shares, shares)}
    else
      {:noreply, socket}
    end
  end

  defp find_message(messages, id), do: Enum.find(messages, &(&1.id == id))

  defp refresh_messages(conversation) do
    messages = NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_messages, [conversation])
    if is_list(messages), do: messages, else: []
  end

  defp tool_calls_for_message(nil), do: []

  defp tool_calls_for_message(message) do
    message
    |> then(fn msg -> Map.get(msg, :metadata) || Map.get(msg, "metadata") || %{} end)
    |> Map.get("tool_calls", [])
    |> normalize_tool_calls()
  end

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    tool_calls
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn tc ->
      %{
        tool_call_id: Map.get(tc, :tool_call_id) || Map.get(tc, "tool_call_id"),
        tool_name: Map.get(tc, :tool_name) || Map.get(tc, "tool_name"),
        timestamp: Map.get(tc, :timestamp) || Map.get(tc, "timestamp"),
        params: Map.get(tc, :params) || Map.get(tc, "params"),
        response: Map.get(tc, :response) || Map.get(tc, "response"),
        response_time_ms: Map.get(tc, :response_time_ms) || Map.get(tc, "response_time_ms"),
        status: Map.get(tc, :status) || Map.get(tc, "status")
      }
    end)
    |> Enum.sort_by(fn tc -> tool_call_sort_key(tc.response_time_ms) end, :desc)
  end

  defp normalize_tool_calls(_), do: []

  defp tool_call_sort_key(ms) when is_integer(ms), do: ms
  defp tool_call_sort_key(ms) when is_float(ms), do: ms
  defp tool_call_sort_key(_), do: -1

  defp infer_feedback_from_ratings([]), do: nil
  defp infer_feedback_from_ratings([%{rating: r} | _]) when r >= 4, do: :positive
  defp infer_feedback_from_ratings([%{rating: r} | _]) when r <= 2, do: :negative
  defp infer_feedback_from_ratings(_), do: nil
end
