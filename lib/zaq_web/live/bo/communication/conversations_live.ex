defmodule ZaqWeb.Live.BO.Communication.ConversationsLive do
  @moduledoc """
  BO LiveView for browsing, filtering, and managing conversations.
  """

  use ZaqWeb, :live_view

  alias Zaq.NodeRouter

  @impl true
  def mount(_params, _session, socket) do
    current_user = socket.assigns[:current_user]
    user_id = if current_user, do: current_user.id, else: nil

    conversations =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_conversations, [
        [user_id: user_id]
      ])

    conversations = if is_list(conversations), do: conversations, else: []

    {:ok,
     socket
     |> assign(:page_title, "Conversations")
     |> assign(:current_path, "/bo/conversations")
     |> assign(:conversations, conversations)
     |> assign(:filter_status, "all")
     |> assign(:filter_channel_type, "all")}
  end

  @impl true
  def handle_event("filter", %{"status" => status, "channel_type" => channel_type}, socket) do
    current_user = socket.assigns[:current_user]
    user_id = if current_user, do: current_user.id, else: nil

    opts =
      [user_id: user_id]
      |> maybe_filter(:status, status)
      |> maybe_filter(:channel_type, channel_type)

    conversations =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_conversations, [opts])

    conversations = if is_list(conversations), do: conversations, else: []

    {:noreply,
     socket
     |> assign(:conversations, conversations)
     |> assign(:filter_status, status)
     |> assign(:filter_channel_type, channel_type)}
  end

  def handle_event("archive", %{"id" => id}, socket) do
    case NodeRouter.call(:engine, Zaq.Engine.Conversations, :get_conversation!, [id]) do
      %{} = conv ->
        NodeRouter.call(:engine, Zaq.Engine.Conversations, :archive_conversation, [conv])
        {:noreply, reload_conversations(socket)}

      _ ->
        {:noreply, socket}
    end
  rescue
    _ -> {:noreply, socket}
  end

  def handle_event("delete", %{"id" => id}, socket) do
    case NodeRouter.call(:engine, Zaq.Engine.Conversations, :get_conversation!, [id]) do
      %{} = conv ->
        NodeRouter.call(:engine, Zaq.Engine.Conversations, :delete_conversation, [conv])
        {:noreply, reload_conversations(socket)}

      _ ->
        {:noreply, socket}
    end
  rescue
    _ -> {:noreply, socket}
  end

  defp reload_conversations(socket) do
    current_user = socket.assigns[:current_user]
    user_id = if current_user, do: current_user.id, else: nil

    conversations =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_conversations, [
        [user_id: user_id]
      ])

    conversations = if is_list(conversations), do: conversations, else: []
    assign(socket, :conversations, conversations)
  end

  defp maybe_filter(opts, _key, "all"), do: opts
  defp maybe_filter(opts, key, value), do: [{key, value} | opts]
end
