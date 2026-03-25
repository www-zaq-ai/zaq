defmodule ZaqWeb.Live.SharedConversationLive do
  @moduledoc "Public read-only view for a shared conversation."

  use ZaqWeb, :live_view

  alias Zaq.NodeRouter

  @impl true
  def mount(%{"token" => token}, _session, socket) do
    conversation =
      NodeRouter.call(:engine, Zaq.Engine.Conversations, :get_conversation_by_token, [token])

    case conversation do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Share link is invalid or has been revoked.")
         |> redirect(to: ~p"/")}

      conv ->
        messages =
          NodeRouter.call(:engine, Zaq.Engine.Conversations, :list_messages, [conv])

        {:ok,
         socket
         |> assign(:page_title, conv.title || "Shared Conversation")
         |> assign(:conversation, conv)
         |> assign(:messages, messages), layout: {ZaqWeb.Layouts, :root}}
    end
  end
end
