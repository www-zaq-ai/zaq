defmodule ZaqWeb.Live.People.ConversationDetailLive do
  @moduledoc "Owned history detail with independently authorized rating and share operations."
  use ZaqWeb, :live_view
  alias Zaq.Engine.Telemetry.FeedbackReasons
  alias ZaqWeb.Components.DesignSystem.{ConversationDetail, PersonHeader}
  alias ZaqWeb.Components.PersonLayout
  alias ZaqWeb.Helpers.Markdown
  alias ZaqWeb.Live.BO.Communication.MessageHelpers
  alias ZaqWeb.Live.People.ConversationAccess, as: Access
  alias ZaqWeb.PersonConversationResource

  @impl true
  def mount(%{"id" => id} = params, session, socket) do
    {:ok,
     socket
     |> put_private(:person_conversation_token, session["person_session_token"])
     |> assign(
       conversation_id: id,
       page_title: "Conversation",
       conversation: nil,
       messages: [],
       shares: [],
       can_share: false,
       show_share_dialog: false,
       show_feedback_modal: false,
       feedback_message_id: nil,
       feedback_reasons: [],
       feedback_comment: "",
       message_info_modal_for: nil,
       message_info_modal: MessageHelpers.empty_message_info(),
       expanded_trace_ids: MapSet.new(),
       preview: nil,
       back_url: "/people/history?" <> URI.encode_query(Access.list_params(params))
     )
     |> refresh()}
  end

  @impl true
  def handle_event(event, params, socket) do
    socket = refresh(socket)

    if socket.redirected,
      do: {:noreply, socket},
      else: {:noreply, detail_event(event, params, socket)}
  end

  defp detail_event("feedback", %{"id" => id, "type" => "positive"}, socket),
    do: rate(socket, id, %{rating: 5})

  defp detail_event("feedback", %{"id" => id, "type" => "negative"}, socket) do
    if Enum.any?(socket.assigns.messages, &(&1.id == id && &1.role == "assistant")),
      do: MessageHelpers.open_feedback_modal(socket, id),
      else: socket
  end

  defp detail_event("submit_feedback", params, socket) do
    comment = MessageHelpers.feedback_comment_from_submit(params, socket.assigns.feedback_comment)
    reasons = socket.assigns.feedback_reasons

    full_comment =
      [Enum.join(reasons, ", "), comment] |> Enum.reject(&(&1 == "")) |> Enum.join("\n")

    socket
    |> rate(socket.assigns.feedback_message_id, %{rating: 1, comment: full_comment})
    |> assign(show_feedback_modal: false)
  end

  defp detail_event("toggle_feedback_reason", %{"reason" => reason}, socket)
       when is_binary(reason) do
    if reason in FeedbackReasons.list(),
      do:
        assign(socket,
          feedback_reasons: MessageHelpers.toggle_reason(socket.assigns.feedback_reasons, reason)
        ),
      else: socket
  end

  defp detail_event("update_feedback_comment", %{"comment" => comment}, socket)
       when is_binary(comment),
       do: assign(socket, feedback_comment: comment)

  defp detail_event("close_feedback_modal", _, socket),
    do: assign(socket, show_feedback_modal: false)

  defp detail_event("open_share_dialog", _, socket) do
    case command(socket, :shares) do
      {:ok, shares} -> assign(socket, shares: shares, show_share_dialog: true)
      {:error, reason} -> operation_error(socket, reason)
    end
  end

  defp detail_event("close_share_dialog", _, socket), do: assign(socket, show_share_dialog: false)

  defp detail_event("share", params, socket) do
    case command(socket, :share, %{attrs: Map.take(params, ["permission", "expires_at"])}) do
      {:ok, _} -> socket |> assign(show_share_dialog: false) |> refresh()
      {:error, reason} -> operation_error(socket, reason)
    end
  end

  defp detail_event("revoke_share", %{"id" => id}, socket) do
    case command(socket, :revoke_share, %{share_id: id}) do
      {:ok, _} -> refresh(socket)
      {:error, reason} -> operation_error(socket, reason)
    end
  end

  defp detail_event("open_message_info_modal", %{"id" => id}, socket) do
    case command(socket, :message, %{message_id: id}) do
      {:ok, message} ->
        assign(socket,
          message_info_modal_for: id,
          message_info_modal: MessageHelpers.message_info_from_message(message),
          expanded_trace_ids: MapSet.new()
        )

      {:error, reason} ->
        operation_error(socket, reason)
    end
  end

  defp detail_event("close_message_info_modal", _, socket),
    do:
      assign(socket,
        message_info_modal_for: nil,
        message_info_modal: MessageHelpers.empty_message_info(),
        expanded_trace_ids: MapSet.new()
      )

  defp detail_event("toggle_trace_details", %{"trace_id" => id}, socket) when is_binary(id),
    do:
      assign(socket,
        expanded_trace_ids:
          MessageHelpers.toggle_trace_details(socket.assigns.expanded_trace_ids, id)
      )

  defp detail_event("copy_message", %{"text" => text}, socket) when is_binary(text),
    do: push_event(socket, "clipboard", %{text: text})

  defp detail_event("open_preview_modal", %{"path" => path}, socket) when is_binary(path) do
    message =
      Enum.find(socket.assigns.messages, fn message ->
        Enum.any?(message.sources || [], &(source_path(&1) == path))
      end)

    if message do
      with {:ok, descriptor} <- command(socket, :source, %{message_id: message.id, source: path}),
           {:ok, resource} <- PersonConversationResource.load(:source, descriptor) do
        assign(socket,
          preview: preview(resource, socket.assigns.conversation_id, message.id, path)
        )
      else
        {:error, reason} ->
          operation_error(assign(socket, preview: nil), reason)
      end
    else
      operation_error(socket, :not_found)
    end
  end

  defp detail_event("close_preview_modal", _, socket), do: assign(socket, preview: nil)
  defp detail_event(_, _, socket), do: socket

  defp rate(socket, id, attrs) do
    case command(socket, :rate, %{message_id: id, attrs: attrs}) do
      {:ok, _} -> refresh(socket)
      {:error, reason} -> operation_error(socket, reason)
    end
  end

  defp command(socket, op, params \\ %{}),
    do:
      Access.command(
        socket,
        op,
        Map.put(params, :conversation_id, socket.assigns.conversation_id)
      )

  defp operation_error(socket, :share_forbidden),
    do:
      socket
      |> assign(can_share: false, shares: [], show_share_dialog: false)
      |> put_flash(:error, "You do not have permission to share conversations.")

  defp operation_error(socket, reason) when reason in [:invalid_session, :forbidden],
    do: Access.denied(socket, reason)

  defp operation_error(socket, _),
    do: put_flash(socket, :error, "Unable to complete this action.")

  defp preview(resource, conversation_id, message_id, source) do
    kind =
      case resource.mime_type do
        "text/markdown" -> :markdown
        "text/plain" -> :text
        "application/pdf" -> :pdf
        type when type in ["image/png", "image/jpeg", "image/gif", "image/webp"] -> :image
        _ -> :binary
      end

    %{
      filename: resource.name,
      relative_path: source,
      ext: Path.extname(resource.name),
      kind: kind,
      content: resource.content,
      rendered_html: if(kind == :markdown, do: Markdown.render(resource.content), else: nil),
      file_size: byte_size(resource.content),
      modified_at: nil,
      raw_url:
        "/people/conversations/#{conversation_id}/messages/#{message_id}/source?" <>
          URI.encode_query(%{"source" => source})
    }
  end

  defp source_path(%{"path" => source}) when is_binary(source), do: source
  defp source_path(%{"source" => source}) when is_binary(source), do: source
  defp source_path(%{"attributes" => %{"source" => source}}) when is_binary(source), do: source
  defp source_path(source) when is_binary(source), do: source
  defp source_path(_), do: nil

  defp refresh(socket) do
    case command(socket, :detail) do
      {:ok, data} ->
        socket =
          assign(socket,
            conversation: data.conversation,
            messages: data.messages,
            shares: data.shares,
            can_share: data.can_share,
            person_permissions: data.permissions,
            current_person: Map.merge(socket.assigns.current_person, data.person)
          )

        if data.can_share, do: socket, else: assign(socket, show_share_dialog: false)

      {:error, reason} ->
        Access.denied(socket, reason)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <PersonLayout.person_layout flash={@flash} authenticated content_width={:wide}>
      <:header>
        <PersonHeader.person_header
          title={(@conversation && @conversation.title) || "Conversation"}
          display_name={@current_person.full_name}
          person_permissions={@person_permissions}
        />
      </:header>
      <ConversationDetail.conversation_detail
        :if={@conversation}
        conversation={@conversation}
        messages={@messages}
        shares={@shares}
        can_share={@can_share}
        bleed={false}
        back_url={@back_url}
        show_share_dialog={@show_share_dialog}
        show_feedback_modal={@show_feedback_modal}
        feedback_reasons={@feedback_reasons}
        feedback_comment={@feedback_comment}
        message_info_modal_for={@message_info_modal_for}
        message_info_modal={@message_info_modal}
        expanded_trace_ids={@expanded_trace_ids}
        preview={@preview}
        source_preview_path={&source_path/1}
        artifact_url={
          fn id ->
            "/people/conversations/#{@conversation_id}/messages/#{@message_info_modal_for}/artifacts/#{id}"
          end
        }
      />
    </PersonLayout.person_layout>
    """
  end
end
