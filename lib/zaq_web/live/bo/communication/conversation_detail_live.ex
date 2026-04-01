defmodule ZaqWeb.Live.BO.Communication.ConversationDetailLive do
  @moduledoc """
  BO LiveView for viewing a conversation thread with per-message ratings and share management.
  """

  use ZaqWeb, :live_view

  alias Zaq.NodeRouter
  alias ZaqWeb.Live.BO.AI.FilePreviewData

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
     |> assign(:preview, nil)}
  rescue
    Ecto.NoResultsError ->
      {:ok,
       socket
       |> put_flash(:error, "Conversation not found.")
       |> redirect(to: ~p"/bo/chat")}
  end

  @impl true
  def handle_event("rate_message", %{"id" => msg_id, "rating" => rating_str}, socket) do
    current_user = socket.assigns[:current_user]

    msg = find_message(socket.assigns.messages, msg_id)

    if msg do
      rater_attrs =
        if current_user,
          do: %{user_id: current_user.id, rating: String.to_integer(rating_str)},
          else: %{rating: String.to_integer(rating_str)}

      NodeRouter.call(:engine, Zaq.Engine.Conversations, :rate_message, [msg, rater_attrs])
    end

    {:noreply, socket}
  end

  def handle_event("open_share_dialog", _params, socket) do
    {:noreply, assign(socket, :show_share_dialog, true)}
  end

  def handle_event("close_share_dialog", _params, socket) do
    {:noreply, assign(socket, :show_share_dialog, false)}
  end

  def handle_event("open_preview_modal", %{"path" => path}, socket) do
    {:noreply, maybe_open_preview(socket, path)}
  end

  def handle_event("close_preview_modal", _params, socket) do
    {:noreply, assign(socket, :preview, nil)}
  end

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

  defp maybe_open_preview(socket, path) do
    case FilePreviewData.load(path, socket.assigns.current_user) do
      {:ok, preview} ->
        assign(socket, :preview, preview)

      {:error, :unauthorized} ->
        put_flash(socket, :error, "You do not have access to this file.")
    end
  end
end
