defmodule ZaqWeb.Live.People.ConversationAccess do
  @moduledoc "Private-token web transport and failure presentation for People conversation pages."
  import Phoenix.Component
  import Phoenix.LiveView
  alias Zaq.Engine.Events

  @doc "Dispatches a fixed confidential Engine operation without exposing transport errors."
  def command(socket, op, params \\ %{}, opts \\ []) do
    params
    |> Map.merge(%{op: op, token: socket.private[:person_conversation_token]})
    |> Events.build_and_dispatch_invoke_event(:people_conversations,
      event_opts: [confidential: true],
      node_router: Keyword.get(opts, :node_router, Zaq.NodeRouter)
    )
    |> Map.fetch!(:response)
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  @doc "Drops sensitive page state before denied reads navigate away."
  def denied(socket, reason) do
    socket =
      assign(socket,
        conversation: nil,
        messages: [],
        shares: [],
        conversations: [],
        preview: nil,
        message_info_modal: %{},
        message_info_modal_for: nil,
        expanded_trace_ids: MapSet.new(),
        feedback_message_id: nil,
        feedback_reasons: [],
        feedback_comment: "",
        show_share_dialog: false,
        show_feedback_modal: false,
        can_share: false
      )

    case reason do
      :invalid_session ->
        socket
        |> put_private(:person_conversation_token, nil)
        |> assign(current_person: nil, person_permissions: MapSet.new(), person_session: nil)
        |> redirect(to: "/people/login")

      :forbidden ->
        socket
        |> put_flash(:error, "You do not have permission to view conversation history.")
        |> redirect(to: "/people/profile")

      :not_found ->
        socket |> put_flash(:error, "Conversation not found.") |> redirect(to: "/people/history")

      _ ->
        socket
        |> put_flash(:error, "Conversation history is unavailable. Please try again.")
        |> redirect(to: "/people/profile")
    end
  end

  @doc "Known local list parameters only; no caller-supplied return destinations."
  def list_params(params) do
    %{
      "status" => scalar(params["status"], "all"),
      "channel_type" => scalar(params["channel_type"], "all"),
      "page" => scalar(params["page"], "1")
    }
  end

  defp scalar(value, _) when is_binary(value), do: value
  defp scalar(_, default), do: default
end
